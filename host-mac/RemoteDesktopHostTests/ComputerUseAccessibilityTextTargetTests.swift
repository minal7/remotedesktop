import ApplicationServices
import Foundation
import XCTest
import AppKit
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseAccessibilityTextTargetTests: XCTestCase {
    func testOptInGmailFocusedRecipientEditorMetadataProbe() throws {
        guard ProcessInfo.processInfo.environment["RUN_GMAIL_FOCUSED_EDITOR_METADATA_PROBE"] == "1" else {
            throw XCTSkip("Set RUN_GMAIL_FOCUSED_EDITOR_METADATA_PROBE=1 with the Gmail recipient control already focused.")
        }
        let started = Date()
        let workspace = NSWorkspace.shared
        guard let app = workspace.frontmostApplication, app.bundleIdentifier == "com.apple.Safari",
              app.isFinishedLaunching,
              let url = URL(string: "https://mail.google.com/"),
              workspace.urlForApplication(toOpen: url)?.standardizedFileURL.path == app.bundleURL?.standardizedFileURL.path else {
            throw XCTSkip("The default Safari must already be frontmost; this probe never activates or opens it.")
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(root, 0.1)
        guard let window = Self.axElement(kAXFocusedWindowAttribute, of: root) else {
            throw XCTSkip("Safari has no readable focused window.")
        }
        _ = AXUIElementSetMessagingTimeout(window, 0.1)
        guard let focused = Self.axElement(kAXFocusedUIElementAttribute, of: root),
              Self.axString(kAXRoleAttribute as String, of: focused) == (kAXComboBoxRole as String) else {
            throw XCTSkip("The focused element is not an AXComboBox.")
        }
        _ = AXUIElementSetMessagingTimeout(focused, 0.1)
        let label = [kAXTitleAttribute as String, kAXDescriptionAttribute as String,
                     kAXPlaceholderValueAttribute as String, kAXHelpAttribute as String,
                     "AXIdentifier"].compactMap { Self.axString($0, of: focused) }
            .first { $0.localizedCaseInsensitiveContains("To recipients") }
        guard label != nil else { throw XCTSkip("The focused combo is not labeled To recipients.") }

        func attribute(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return nil }
            return raw
        }
        func attributeKind(_ raw: CFTypeRef?) -> String {
            guard let raw else { return "missing" }
            if CFGetTypeID(raw) == AXValueGetTypeID() { return "AXValue" }
            if CFGetTypeID(raw) == CFStringGetTypeID() { return "string" }
            if CFGetTypeID(raw) == CFBooleanGetTypeID() { return "boolean" }
            if CFGetTypeID(raw) == CFNumberGetTypeID() { return "number" }
            return "other"
        }
        func settable(_ name: String) -> Bool? {
            var result = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(focused, name as CFString, &result) == .success else { return nil }
            return result.boolValue
        }
        var ancestors: [[String: Any]] = []
        var current: AXUIElement? = focused
        var reachedWindow = false
        var webAreaURL: String?
        var webAreaFound = false
        var seen: [AXUIElement] = []
        for _ in 0 ..< 20 {
            guard !Task.isCancelled, Date().timeIntervalSince(started) < 1.5 else {
                throw XCTSkip("The bounded metadata observation expired.")
            }
            guard let element = current, !seen.contains(where: { CFEqual($0, element) }) else { break }
            seen.append(element)
            _ = AXUIElementSetMessagingTimeout(element, 0.1)
            let ancestorRole = Self.axString(kAXRoleAttribute as String, of: element) ?? ""
            let ancestor: [String: Any] = ["role": ancestorRole]
            if ancestorRole == "AXWebArea" {
                webAreaFound = true
                let rawDocument = attribute(kAXDocumentAttribute as String, element)
                    ?? attribute("AXURL", element)
                let document = (rawDocument as? String) ?? (rawDocument as? URL)?.absoluteString
                if let document, let parsed = URL(string: document), parsed.scheme == "https",
                   parsed.host == "mail.google.com" { webAreaURL = parsed.absoluteString }
            }
            guard ancestorRole != "AXSecureTextField",
                  Self.axString(kAXSubroleAttribute as String, of: element) != (kAXSecureTextFieldSubrole as String),
                  Self.axBool("AXProtectedContent", of: element) != true,
                  Self.axBool("AXHidden", of: element) != true else {
                throw XCTSkip("The focused ancestry is hidden or protected; no value is read.")
            }
            ancestors.append(ancestor)
            if CFEqual(element, window) { reachedWindow = true; break }
            current = Self.axElement(kAXParentAttribute as String, of: element)
        }
        guard webAreaFound, webAreaURL != nil, reachedWindow,
              workspace.frontmostApplication?.processIdentifier == app.processIdentifier,
              let currentWindow = Self.axElement(kAXFocusedWindowAttribute, of: root), CFEqual(currentWindow, window),
              let currentFocus = Self.axElement(kAXFocusedUIElementAttribute, of: root), CFEqual(currentFocus, focused) else {
            throw XCTSkip("The focused combo was not within the retained mail.google.com web area/window, or scope changed.")
        }
        let role = Self.axString(kAXRoleAttribute as String, of: focused) ?? ""
        let subrole = Self.axString(kAXSubroleAttribute as String, of: focused)
        let enabled = Self.axBool(kAXEnabledAttribute as String, of: focused)
        let editable = Self.axBool("AXEditable", of: focused)
        let rawValue = attribute(kAXValueAttribute as String, focused)
        let valueType = attributeKind(rawValue)
        let valueByteLength = (rawValue as? String)?.utf8.count
        let rawSelection = attribute(kAXSelectedTextRangeAttribute as String, focused)
        let selectionType = attributeKind(rawSelection)
        var selectionLocation: Int?
        var selectionLength: Int?
        if let rawSelection, CFGetTypeID(rawSelection) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rawSelection as! AXValue, .cfRange, &range) {
                selectionLocation = range.location
                selectionLength = range.length
            }
        }
        let protected = Self.axBool("AXProtectedContent", of: focused)
        let hidden = Self.axBool("AXHidden", of: focused)
        let snapshotAvailable = ComputerUseAccessibilityTextTarget().snapshot() != nil
        guard workspace.frontmostApplication?.processIdentifier == app.processIdentifier,
              let finalWindow = Self.axElement(kAXFocusedWindowAttribute, of: root), CFEqual(finalWindow, window),
              let finalFocus = Self.axElement(kAXFocusedUIElementAttribute, of: root), CFEqual(finalFocus, focused) else {
            XCTFail("The read-only snapshot probe unexpectedly changed focus or window.")
            return
        }
        let report: [String: Any] = [
            "probe": "Gmail focused recipient AXComboBox metadata (values omitted)",
            "role": role, "subrole": subrole as Any? ?? NSNull(), "label": label!,
            "enabled": enabled as Any? ?? NSNull(), "editable": editable as Any? ?? NSNull(),
            "valueSettable": settable(kAXValueAttribute as String) as Any? ?? NSNull(),
            "selectedTextSettable": settable(kAXSelectedTextAttribute as String) as Any? ?? NSNull(),
            "valueType": valueType, "valueByteLength": valueByteLength as Any? ?? NSNull(),
            "selectionType": selectionType, "selectionLocation": selectionLocation as Any? ?? NSNull(),
            "selectionLength": selectionLength as Any? ?? NSNull(),
            "protected": protected as Any? ?? NSNull(), "hidden": hidden as Any? ?? NSNull(),
            "ancestorRoles": ancestors, "reachedFocusedWindow": reachedWindow,
            "sameMailWebAreaURL": webAreaURL!, "snapshotAvailable": snapshotAvailable,
            "elapsedSeconds": Date().timeIntervalSince(started)
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "gmail-focused-recipient-editor-metadata.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 2.0, "AX metadata probe exceeded its bound")
        XCTAssertTrue(snapshotAvailable, "The observed focused recipient combo has valid editable AX state")
    }

    func testOptInSafariAddressFieldFingerprintAndLifecycleStability() async throws {
        try await runOptInFocusedFieldLifecycleProbe(mode: .safariAddress)
    }

    func testOptInGmailRecipientFingerprintAndLifecycleStability() async throws {
        try await runOptInFocusedFieldLifecycleProbe(mode: .gmailRecipient)
    }

    func testOptInGmailComposeRecipientFingerprintAndLifecycleStability() async throws {
        guard ProcessInfo.processInfo.environment["RUN_GMAIL_COMPOSE_RECIPIENT_STABILITY_PROBE"] == "1" else {
            throw XCTSkip("Set RUN_GMAIL_COMPOSE_RECIPIENT_STABILITY_PROBE=1 to open one empty Gmail compose and observe its focused editor.")
        }
        let started = Date()
        let workspace = NSWorkspace.shared
        guard let safari = workspace.frontmostApplication, safari.bundleIdentifier == "com.apple.Safari",
              safari.isFinishedLaunching,
              let mailURL = URL(string: "https://mail.google.com/"),
              workspace.urlForApplication(toOpen: mailURL)?.standardizedFileURL.path == safari.bundleURL?.standardizedFileURL.path,
              let application = ComputerUseApplicationIdentity(runningApplication: safari) else {
            throw XCTSkip("Default Safari must already be frontmost on Gmail; the probe never activates or navigates it.")
        }
        let root = AXUIElementCreateApplication(safari.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(root, 0.1)
        guard let window = Self.axElement(kAXFocusedWindowAttribute, of: root),
              let initialFocus = Self.axElement(kAXFocusedUIElementAttribute, of: root),
              let windowBounds = Self.axFrame(window) else {
            throw XCTSkip("Safari has no readable retained Gmail window or focused element.")
        }
        let initialContext = Self.focusedAXContext(initialFocus, window: window)
        guard initialContext?.isMailWebArea == true else {
            throw XCTSkip("The initial focused element is not inside the retained mail.google.com web area.")
        }

        var recorder: AXProbeLifecycleRecorder?
        var access = ComputerUseAccessibilityTextTarget.Access.live
        let lifecycleFactory = access.makeLifecycleMonitor
        access.makeLifecycleMonitor = { app in
            let monitor = lifecycleFactory?(app) ?? ComputerUseAXLifecycleMonitor(application: app.root)
            let wrapper = AXProbeLifecycleRecorder(monitor, focused: initialFocus, window: window,
                appRoot: root, ancestors: initialContext?.ancestors ?? [initialFocus, window, root])
            recorder = wrapper
            return wrapper
        }
        let target = ComputerUseAccessibilityTextTarget(access: access)
        _ = target.snapshot() // Installs the forwarding lifecycle observer before the Compose control is located.
        guard let lifecycle = recorder else { throw XCTSkip("The real AX lifecycle observer was unavailable.") }
        defer { lifecycle.cancel() }

        let reader = ComputerUseDefaultBrowserPageReader()
        guard let page = try reader.read(window: window, application: application, mayAct: { true }),
              let observedURL = URL(string: page.url), observedURL.scheme == "https", observedURL.host == "mail.google.com",
              !page.renderedAXText.localizedCaseInsensitiveContains("Compose:") else {
            throw XCTSkip("A retained Gmail page observation was unavailable.")
        }
        let composeControls = page.controls.filter {
            $0.role == "AXButton" && $0.label.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Compose") == .orderedSame && $0.enabled == true
        }
        guard composeControls.count == 1, let compose = composeControls.first,
              try reader.validatedControlCenter(observation: page, controlID: compose.id,
                  window: window, windowBounds: windowBounds, mayAct: { true }) != nil,
              let composeElement = reader.retainedControl(observationID: page.id, controlID: compose.id,
                  application: application, window: window),
              Self.axBool(kAXEnabledAttribute as String, of: composeElement) == true,
              Self.axString(kAXRoleAttribute as String, of: composeElement) == "AXButton" else {
            throw XCTSkip("Gmail did not expose one uniquely validated enabled Compose button; no action was sent.")
        }
        let composePressStatus = AXUIElementPerformAction(composeElement, kAXPressAction as CFString)

        var samples: [[String: Any]] = []
        var events: [[String: Any]] = []
        var recipientBaseline: (snapshot: ComputerUseTextSnapshot, context: FocusedAXContext)?
        for index in 0..<32 {
            try Task.checkCancellation()
            var row: [String: Any] = ["index": index]
            lifecycle.beginSample(index)
            let frontmost = workspace.frontmostApplication?.processIdentifier == safari.processIdentifier
            let windowMatches = Self.axElement(kAXFocusedWindowAttribute, of: root).map { CFEqual($0, window) } ?? false
            guard frontmost, windowMatches,
                  let focus = Self.axElement(kAXFocusedUIElementAttribute, of: root),
                  let context = Self.focusedAXContext(focus, window: window), context.isMailWebArea else {
                row["scopeAvailable"] = false
                row["frontmostMatches"] = frontmost
                row["windowMatches"] = windowMatches
                row["focusedRoleIsRecipientCombo"] = false
                samples.append(row)
                events.append(contentsOf: lifecycle.takeCapturedEvents())
                if index < 31 { try await Task.sleep(for: .milliseconds(250)) }
                continue
            }
            lifecycle.updateContext(focused: focus, window: window, appRoot: root, ancestors: context.ancestors)
            let snapshot = target.snapshot() // The target itself drains; never drain the monitor independently.
            events.append(contentsOf: lifecycle.takeCapturedEvents())
            let isRecipient = context.role == (kAXComboBoxRole as String)
                && context.labels.contains(where: { $0.localizedCaseInsensitiveContains("To recipients") })
            row["scopeAvailable"] = true
            row["frontmostMatches"] = frontmost
            row["windowMatches"] = windowMatches
            row["focusedRoleIsRecipientCombo"] = isRecipient
            row["snapshotAvailable"] = snapshot != nil
            row["targetMatchesFirstRecipient"] = snapshot.flatMap { value in recipientBaseline.map { value.targetID == $0.snapshot.targetID } } as Any? ?? NSNull()
            row["valueMatchesFirstRecipient"] = snapshot.flatMap { value in recipientBaseline.map { value.value == $0.snapshot.value } } as Any? ?? NSNull()
            row["valueByteCount"] = snapshot?.value.utf8.count as Any? ?? NSNull()
            row["selectionLocation"] = snapshot?.selection.location as Any? ?? NSNull()
            row["selectionLength"] = snapshot?.selection.length as Any? ?? NSNull()
            row["editable"] = snapshot?.isEditable as Any? ?? NSNull()
            row["secure"] = snapshot?.isSecure as Any? ?? NSNull()
            if isRecipient, let snapshot {
                if recipientBaseline == nil { recipientBaseline = (snapshot, context) }
                if let baseline = recipientBaseline {
                    row["focusedHandleMatchesFirstRecipient"] = CFEqual(focus, baseline.context.element)
                    row["ancestryMatchesFirstRecipient"] = context.ancestors.count == baseline.context.ancestors.count
                        && zip(context.ancestors, baseline.context.ancestors).allSatisfy { CFEqual($0.0, $0.1) }
                    row["visibleAttributesMatchFirstRecipient"] = context.role == baseline.context.role
                        && context.subrole == baseline.context.subrole
                        && context.identifier == baseline.context.identifier
                        && context.labels == baseline.context.labels
                    row["documentPartsMatchFirstRecipient"] = context.documentParts == baseline.context.documentParts
                    row["windowTitleMatchesFirstRecipient"] = context.windowTitle == baseline.context.windowTitle
                }
            }
            samples.append(row)
            if index < 31 { try await Task.sleep(for: .milliseconds(250)) }
        }
        let report: [String: Any] = ["probe": "Gmail Compose recipient lifecycle (no typed value or URL serialized)",
            "composeAXPressStatus": composePressStatus.rawValue, "composeObservationCount": samples.count,
            "pageObservationTruncated": page.truncated,
            "recipientFocusedAtLeastOnce": recipientBaseline != nil, "samples": samples,
            "eventSummaryCount": events.count, "events": events,
            "elapsedSeconds": Date().timeIntervalSince(started)]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "gmail-compose-recipient-lifecycle.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(samples.count, 32)
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 15.0)
    }

    func testOptInGmailScriptedRecipientTypingAfterPlanningDelay() async throws {
        guard ProcessInfo.processInfo.environment["RUN_GMAIL_SCRIPTED_RECIPIENT_TYPING_PROBE"] == "1" else {
            throw XCTSkip("Set RUN_GMAIL_SCRIPTED_RECIPIENT_TYPING_PROBE=1 to open one empty Gmail compose, wait through a planning interval, and type without sending.")
        }
        let started = Date()
        let workspace = NSWorkspace.shared
        guard let safari = workspace.frontmostApplication, safari.bundleIdentifier == "com.apple.Safari",
              safari.isFinishedLaunching,
              let mailURL = URL(string: "https://mail.google.com/"),
              workspace.urlForApplication(toOpen: mailURL)?.standardizedFileURL.path == safari.bundleURL?.standardizedFileURL.path,
              let application = ComputerUseApplicationIdentity(runningApplication: safari) else {
            throw XCTSkip("Default Safari must already be frontmost on Gmail; this probe never opens or navigates a window.")
        }
        let appRoot = AXUIElementCreateApplication(safari.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(appRoot, 0.1)
        guard let window = Self.axElement(kAXFocusedWindowAttribute, of: appRoot),
              let initialFocus = Self.axElement(kAXFocusedUIElementAttribute, of: appRoot),
              let initialContext = Self.focusedAXContext(initialFocus, window: window),
              initialContext.isMailWebArea,
              let windowBounds = Self.axFrame(window) else {
            throw XCTSkip("The retained Safari window is not a readable Gmail page.")
        }

        var recorder: AXProbeLifecycleRecorder?
        var access = ComputerUseAccessibilityTextTarget.Access.live
        let lifecycleFactory = access.makeLifecycleMonitor
        access.makeLifecycleMonitor = { app in
            let monitor = lifecycleFactory?(app) ?? ComputerUseAXLifecycleMonitor(application: app.root)
            let wrapper = AXProbeLifecycleRecorder(monitor, focused: initialFocus, window: window,
                appRoot: appRoot, ancestors: initialContext.ancestors)
            recorder = wrapper
            return wrapper
        }
        let target = ComputerUseAccessibilityTextTarget(access: access)
        _ = target.snapshot()
        guard let lifecycle = recorder else { throw XCTSkip("The forwarding AX lifecycle observer was unavailable.") }
        defer { lifecycle.cancel() }

        let reader = ComputerUseDefaultBrowserPageReader()
        guard let page = try reader.read(window: window, application: application, mayAct: { true }),
              let pageURL = URL(string: page.url), pageURL.scheme == "https", pageURL.host == "mail.google.com",
              !page.renderedAXText.localizedCaseInsensitiveContains("Compose:") else {
            throw XCTSkip("Gmail must be on its main page with no existing compose pane.")
        }
        let composeButtons = page.controls.filter {
            $0.role == "AXButton" && $0.enabled == true
                && $0.label.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Compose") == .orderedSame
        }
        guard composeButtons.count == 1, let compose = composeButtons.first,
              let center = try reader.validatedControlCenter(observation: page, controlID: compose.id,
                  window: window, windowBounds: windowBounds, mayAct: { true }) else {
            throw XCTSkip("No unique fresh enabled Compose control was available; no action was sent.")
        }

        var proposals = 0
        var proposalTimes: [TimeInterval] = []
        var planningDelayCompletedAt: TimeInterval?
        var executionResult = "not started"
        var typedDispatches = 0
        var revalidationDiagnostics: [[String: String]] = []
        let journalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmail-scripted-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: journalDirectory) }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { !Task.isCancelled },
            nativeTextTarget: target)
        let executor = try ComputerUseDesktopExecutor(
            journalDirectory: journalDirectory,
            propose: { input in
                proposals += 1
                proposalTimes.append(Date().timeIntervalSince(started))
                lifecycle.beginSample(proposals)
                switch proposals {
                case 1:
                    guard let bounds = input.desktopDisplayBounds, bounds.width > 0, bounds.height > 0 else {
                        throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged
                    }
                    let point = ComputerUseFaraAction.Point(
                        x: (Double(center.x - bounds.minX) / Double(bounds.width)) * 1000,
                        y: (Double(center.y - bounds.minY) / Double(bounds.height)) * 1000)
                    return .init(response: "Open the compose form.", action: .pointer(.leftClick, point))
                case 2:
                    if let focus = Self.axElement(kAXFocusedUIElementAttribute as String, of: appRoot),
                       let context = Self.focusedAXContext(focus, window: window) {
                        lifecycle.updateContext(focused: focus, window: window, appRoot: appRoot,
                            ancestors: context.ancestors)
                    }
                    try await Task.sleep(for: .seconds(13)) // Model-planning delay, with no UI or keyboard input.
                    planningDelayCompletedAt = Date().timeIntervalSince(started)
                    lifecycle.beginSample(2_001)
                    return .init(response: "Enter the recipient.", action: .typeText("spiderali97@gmail.com"))
                default:
                    return .init(response: "Stop before sending.", decision: .handoff("Recipient typing probe finished; no email was sent."))
                }
            }, surfaceScopeCheck: { _ in
                try Task.checkCancellation()
                guard workspace.frontmostApplication?.processIdentifier == safari.processIdentifier,
                      let activeWindow = Self.axElement(kAXFocusedWindowAttribute, of: appRoot), CFEqual(activeWindow, window),
                      let activeFocus = Self.axElement(kAXFocusedUIElementAttribute, of: appRoot),
                      let activeContext = Self.focusedAXContext(activeFocus, window: window), activeContext.isMailWebArea else {
                    throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged
                }
                lifecycle.updateContext(focused: activeFocus, window: window, appRoot: appRoot,
                    ancestors: activeContext.ancestors)
            }, revalidationFailureObserver: { _, _, _, diagnostics in
                revalidationDiagnostics.append(diagnostics.merging(["elapsedSeconds": String(Date().timeIntervalSince(started))]) { _, new in new })
            }, onSuccessfulDispatch: { action in
                if case .typeText = action { typedDispatches += 1 }
            })
        do {
            let result = try await executor.execute(taskID: "gmail-scripted-recipient-\(UUID().uuidString)",
                prompt: "Open the Gmail compose form and enter a recipient. Do not send.",
                trustedUserPrompt: "Open the Gmail compose form and enter a recipient. Do not send.",
                tools: tools, progress: { _ in })
            executionResult = String(describing: result)
        } catch {
            executionResult = "error: \(error.localizedDescription)"
        }
        let recipientSnapshot = target.snapshot()
        let currentFocus = Self.axElement(kAXFocusedUIElementAttribute as String, of: appRoot)
        let postActionSnapshot = target.snapshot()
        let events = lifecycle.takeCapturedEvents()
        let report: [String: Any] = [
            "probe": "scripted Gmail compose and delayed recipient typing; no send action",
            "composeControlWasValidated": true, "proposalCount": proposals,
            "proposalTimesSeconds": proposalTimes, "planningDelayCompletedAtSeconds": planningDelayCompletedAt as Any? ?? NSNull(),
            "executionResult": executionResult,
            "typedDispatchCount": typedDispatches,
            "typingSnapshotAvailable": recipientSnapshot != nil,
            "typingValueByteCount": recipientSnapshot?.value.utf8.count as Any? ?? NSNull(),
            "typingValueMatchesExpected": recipientSnapshot?.value == "spiderali97@gmail.com",
            "typingTargetMatchesPostActionSnapshot": recipientSnapshot.map { $0.targetID == postActionSnapshot?.targetID } as Any? ?? NSNull(),
            "focusedRoleAfterAction": currentFocus.flatMap { Self.axString(kAXRoleAttribute as String, of: $0) } as Any? ?? NSNull(),
            "lifecycleEventSummaries": events, "revalidationDiagnosticCount": revalidationDiagnostics.count,
            "revalidationDiagnostics": revalidationDiagnostics, "elapsedSeconds": Date().timeIntervalSince(started)
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "gmail-scripted-recipient-typing.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 35)
        XCTAssertLessThanOrEqual(proposals, 3)
        XCTAssertLessThanOrEqual(typedDispatches, 1)
    }

    private struct FocusedAXContext {
        let element: AXUIElement
        let ancestors: [AXUIElement]
        let role: String
        let subrole: String
        let identifier: String
        let labels: [String]
        let windowTitle: String
        let documentParts: [String]
        let isMailWebArea: Bool
    }

    private static func focusedAXContext(_ focus: AXUIElement, window: AXUIElement) -> FocusedAXContext? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        var current: AXUIElement? = focus
        var ancestors: [AXUIElement] = []
        var roles: [String] = []
        var documentParts = [axString(kAXTitleAttribute as String, of: window) ?? ""]
        var isMailWebArea = false
        var reachedWindow = false
        while let element = current, ancestors.count < 32, ContinuousClock.now < deadline {
            if ancestors.contains(where: { CFEqual($0, element) }) { return nil }
            _ = AXUIElementSetMessagingTimeout(element, 0.1)
            ancestors.append(element)
            let role = axString(kAXRoleAttribute as String, of: element) ?? ""
            roles.append(role)
            guard role != "AXSecureTextField", axString(kAXSubroleAttribute as String, of: element) != (kAXSecureTextFieldSubrole as String),
                  axBool("AXProtectedContent", of: element) != true, axBool("AXHidden", of: element) != true else { return nil }
            for attribute in [kAXDocumentAttribute as String, "AXURL"] {
                var raw: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
                   let value = (raw as? String) ?? (raw as? URL)?.absoluteString {
                    documentParts.append(value)
                    if role == "AXWebArea", let url = URL(string: value), url.scheme == "https", url.host == "mail.google.com" {
                        isMailWebArea = true
                    }
                }
            }
            if CFEqual(element, window) { reachedWindow = true; break }
            current = axElement(kAXParentAttribute as String, of: element)
        }
        guard reachedWindow, ContinuousClock.now < deadline else { return nil }
        let subrole = axString(kAXSubroleAttribute as String, of: focus) ?? ""
        let identifier = axString("AXIdentifier", of: focus) ?? ""
        let labels = [kAXTitleAttribute as String, kAXDescriptionAttribute as String,
            kAXPlaceholderValueAttribute as String, kAXHelpAttribute as String].compactMap { axString($0, of: focus) }
        return FocusedAXContext(element: focus, ancestors: ancestors, role: roles.first ?? "",
            subrole: subrole, identifier: identifier, labels: labels,
            windowTitle: axString(kAXTitleAttribute as String, of: window) ?? "",
            documentParts: documentParts, isMailWebArea: isMailWebArea)
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private enum FocusedFieldProbeMode: Equatable {
        case safariAddress
        case gmailRecipient

        var environmentKey: String {
            switch self {
            case .safariAddress: return "RUN_SAFARI_FOCUS_STABILITY_PROBE"
            case .gmailRecipient: return "RUN_GMAIL_RECIPIENT_STABILITY_PROBE"
            }
        }
    }

    private func runOptInFocusedFieldLifecycleProbe(mode: FocusedFieldProbeMode) async throws {
        guard ProcessInfo.processInfo.environment[mode.environmentKey] == "1" else {
            throw XCTSkip("Set \(mode.environmentKey)=1 to sample the already-focused Safari field.")
        }

        let workspace = NSWorkspace.shared
        guard let safari = workspace.frontmostApplication,
              safari.bundleIdentifier == "com.apple.Safari",
              safari.isFinishedLaunching else {
            throw XCTSkip("Safari must already be frontmost; this probe never activates or opens it.")
        }
        guard let httpsURL = URL(string: "https://example.com/"),
              let defaultHTTPSHandler = workspace.urlForApplication(toOpen: httpsURL),
              defaultHTTPSHandler.standardizedFileURL.path == safari.bundleURL?.standardizedFileURL.path else {
            throw XCTSkip("Safari is not the current default HTTPS handler.")
        }
        let appRoot = AXUIElementCreateApplication(safari.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(appRoot, 0.15)
        guard let window = Self.axElement(kAXFocusedWindowAttribute, of: appRoot),
              let focused = Self.axElement(kAXFocusedUIElementAttribute, of: appRoot) else {
            throw XCTSkip("Safari has no readable focused window and field.")
        }
        _ = AXUIElementSetMessagingTimeout(window, 0.15)
        _ = AXUIElementSetMessagingTimeout(focused, 0.15)
        let role = Self.axString(kAXRoleAttribute as String, of: focused) ?? ""
        let label = [kAXTitleAttribute as String, kAXDescriptionAttribute as String,
                     kAXPlaceholderValueAttribute as String, kAXHelpAttribute as String,
                     "AXIdentifier"].compactMap { Self.axString($0, of: focused) }
            .first { $0.localizedCaseInsensitiveContains("To recipients") }
        let verifiedMode: Bool
        switch mode {
        case .safariAddress:
            verifiedMode = Self.axString("AXIdentifier", of: focused) == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
                && role == (kAXTextFieldRole as String)
        case .gmailRecipient:
            verifiedMode = role == (kAXComboBoxRole as String) && label != nil
        }
        guard verifiedMode,
              Self.axString(kAXSubroleAttribute as String, of: focused) != (kAXSecureTextFieldSubrole as String),
              Self.axBool("AXProtectedContent", of: focused) != true,
              Self.axBool("AXHidden", of: focused) != true,
              let initialValue = Self.axString(kAXValueAttribute as String, of: focused),
              initialValue.isEmpty else {
            throw XCTSkip("The currently focused Safari field is not the requested readable probe target.")
        }

        let started = Date()
        let ancestryDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var retainedAncestors = [focused, window, appRoot]
        var ancestor = Self.axElement(kAXParentAttribute as String, of: focused)
        var reachedWindow = false
        var reachedMailWebArea = false
        while let current = ancestor, retainedAncestors.count < 32,
              ContinuousClock.now < ancestryDeadline, !Task.isCancelled {
            if CFEqual(current, window) { reachedWindow = true; break }
            if retainedAncestors.contains(where: { CFEqual($0, current) }) { break }
            retainedAncestors.append(current)
            _ = AXUIElementSetMessagingTimeout(current, 0.1)
            if mode == .gmailRecipient,
               Self.axString(kAXRoleAttribute as String, of: current) == "AXWebArea" {
                var rawURL: CFTypeRef?
                let documentStatus = AXUIElementCopyAttributeValue(current, kAXDocumentAttribute as CFString, &rawURL)
                if documentStatus != .success { rawURL = nil }
                if rawURL == nil {
                    let urlStatus = AXUIElementCopyAttributeValue(current, "AXURL" as CFString, &rawURL)
                    if urlStatus != .success { rawURL = nil }
                }
                let urlText = (rawURL as? String) ?? (rawURL as? URL)?.absoluteString
                if let urlText, let url = URL(string: urlText), url.scheme == "https", url.host == "mail.google.com" {
                    reachedMailWebArea = true
                }
            }
            ancestor = Self.axElement(kAXParentAttribute as String, of: current)
        }
        let ancestryWithinDeadline = ContinuousClock.now < ancestryDeadline
        guard reachedWindow,
              mode != .gmailRecipient || reachedMailWebArea,
              ancestryWithinDeadline else {
            throw XCTSkip("Focused-field ancestry unavailable (window=\(reachedWindow), mailWebArea=\(reachedMailWebArea), ancestors=\(retainedAncestors.count), withinDeadline=\(ancestryWithinDeadline)).")
        }
        var access = ComputerUseAccessibilityTextTarget.Access.live
        var recordingLifecycle: AXProbeLifecycleRecorder?
        let lifecycleFactory = access.makeLifecycleMonitor
        access.makeLifecycleMonitor = { application in
            let monitor = lifecycleFactory?(application) ?? ComputerUseAXLifecycleMonitor(application: application.root)
            let recorder = AXProbeLifecycleRecorder(monitor, focused: focused, window: window,
                appRoot: appRoot, ancestors: retainedAncestors)
            recordingLifecycle = recorder
            return recorder
        }
        let target = ComputerUseAccessibilityTextTarget(access: access)
        recordingLifecycle?.beginSample(-1)
        guard let initialSnapshot = target.snapshot(), initialSnapshot.value.isEmpty,
              workspace.frontmostApplication?.processIdentifier == safari.processIdentifier,
              let focusedAfterSnapshot = Self.axElement(kAXFocusedUIElementAttribute, of: appRoot),
              CFEqual(focusedAfterSnapshot, focused) else {
            throw XCTSkip("Safari smart address field does not expose a bounded editable text snapshot.")
        }
        guard let lifecycle = recordingLifecycle else { throw XCTSkip("Safari lifecycle observer was unavailable.") }
        defer { lifecycle.cancel() }

        var samples: [[String: Any]] = []
        var events: [[String: Any]] = []
        events.append(contentsOf: lifecycle.takeCapturedEvents())
        for index in 0..<40 {
            try Task.checkCancellation()
            var row: [String: Any] = ["index": index]
            lifecycle.beginSample(index)
            let focusedWindowMatches = Self.axElement(kAXFocusedWindowAttribute, of: appRoot).map { CFEqual($0, window) } ?? false
            let focusMatches = Self.axElement(kAXFocusedUIElementAttribute, of: appRoot).map { CFEqual($0, focused) } ?? false
            let snapshot = target.snapshot()
            guard workspace.frontmostApplication?.processIdentifier == safari.processIdentifier,
                  focusedWindowMatches, focusMatches,
                  (mode == .safariAddress
                    ? Self.axString("AXIdentifier", of: focused) == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
                    : Self.axString(kAXRoleAttribute as String, of: focused) == (kAXComboBoxRole as String) && label != nil),
                  let snapshot else {
                row["known"] = false
                row["snapshotAvailable"] = false
                row["targetMatchesBaseline"] = NSNull()
                row["valueMatchesBaseline"] = NSNull()
                row["selectionMatchesBaseline"] = NSNull()
                row["editableMatchesBaseline"] = NSNull()
                row["secureMatchesBaseline"] = NSNull()
                row["frontmostMatches"] = workspace.frontmostApplication?.processIdentifier == safari.processIdentifier
                row["windowMatches"] = focusedWindowMatches
                row["focusMatches"] = focusMatches
                samples.append(row)
                events.append(contentsOf: lifecycle.takeCapturedEvents())
                if index < 39 { try await Task.sleep(for: .milliseconds(375)) }
                continue
            }
            row["known"] = true
            row["snapshotAvailable"] = true
            row["targetMatchesBaseline"] = snapshot.targetID == initialSnapshot.targetID
            row["valueMatchesBaseline"] = snapshot.value == initialSnapshot.value
            row["valueByteCount"] = snapshot.value.utf8.count
            row["selectionMatchesBaseline"] = snapshot.selection == initialSnapshot.selection
            row["selectionLocation"] = snapshot.selection.location
            row["selectionLength"] = snapshot.selection.length
            row["editableMatchesBaseline"] = snapshot.isEditable == initialSnapshot.isEditable
            row["editable"] = snapshot.isEditable
            row["secureMatchesBaseline"] = snapshot.isSecure == initialSnapshot.isSecure
            row["secure"] = snapshot.isSecure
            row["frontmostMatches"] = true
            row["windowMatches"] = focusedWindowMatches
            row["focusMatches"] = focusMatches
            samples.append(row)

            events.append(contentsOf: lifecycle.takeCapturedEvents())
            if index < 39 { try await Task.sleep(for: .milliseconds(375)) }
        }
        let modeName = mode == .gmailRecipient ? "read-only Gmail recipient field stability" : "read-only Safari address field stability"
        let report: [String: Any] = ["probe": modeName, "samples": samples,
            "sampleCount": samples.count, "elapsedSeconds": Date().timeIntervalSince(started),
            "eventSummaryCount": events.count, "events": events,
            "baselineValueByteCount": initialSnapshot.value.utf8.count,
            "baselineSelectionLocation": initialSnapshot.selection.location,
            "baselineSelectionLength": initialSnapshot.selection.length,
            "sameMailWebArea": mode == .gmailRecipient ? (reachedMailWebArea as Any) : NSNull(),
            "reachedFocusedWindow": reachedWindow]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = mode == .gmailRecipient ? "gmail-recipient-field-stability.json" : "safari-address-field-stability.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(samples.count, 40)
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 30.0, "Focused-field stability probe exceeded its bound")
        if mode == .gmailRecipient {
            XCTAssertTrue(reachedMailWebArea)
        }
    }

    private static func axElement(_ name: String, of element: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func axString(_ name: String, of element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    private static func axBool(_ name: String, of element: AXUIElement) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return nil }
        return raw as? Bool
    }

    func testNativeWindowContextPreservesObservedRolesAndUnknownModality() throws {
        for (role, subrole, modal) in [("AXWindow", "AXStandardWindow", false), ("AXWindow", "AXDialog", true),
                                       ("AXSheet", "", nil), ("", "", nil)] as [(String, String, Bool?)] {
            let graph = AXTextGraph(), bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
            graph.setFrame("window", bounds)
            graph.set("window", kAXRoleAttribute, role.isEmpty ? nil : role as NSString)
            graph.set("window", kAXSubroleAttribute, subrole.isEmpty ? nil : subrole as NSString)
            graph.set("window", kAXModalAttribute, modal.map { $0 ? kCFBooleanTrue : kCFBooleanFalse })
            graph.set("window", kAXTitleAttribute, "Untrusted \"title\" — cafe\u{301}" as NSString)
            let catalog = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: bounds, windowBounds: bounds,
                access: graph.access, mayAct: { true }))
            let window = try XCTUnwrap(catalog.jsonObject["window"] as? [String: Any])
            if role.isEmpty { XCTAssertTrue(window["role"] is NSNull) } else { XCTAssertEqual(window["role"] as? String, role) }
            if subrole.isEmpty { XCTAssertTrue(window["subrole"] is NSNull) } else { XCTAssertEqual(window["subrole"] as? String, subrole) }
            if let modal { XCTAssertEqual(window["modal"] as? Bool, modal) } else { XCTAssertTrue(window["modal"] is NSNull) }
            XCTAssertEqual(Array((try XCTUnwrap(window["title"] as? String)).utf8), Array("Untrusted \"title\" — cafe\u{301}".utf8))
            XCTAssertEqual(window["truncated"] as? Bool, false)
            XCTAssertEqual(graph.readCount("window", kAXValueAttribute), 0)
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeWindowContextBoundsTitlesAndDoesNotExposeProtectedWindows() throws {
        for mode in ["long-title", "malformed", "secure", "protected", "hidden"] {
            let graph = AXTextGraph(), bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
            graph.setFrame("window", bounds)
            graph.set("window", kAXTitleAttribute, String(repeating: "👩🏽‍💻", count: 80) as NSString)
            switch mode {
            case "malformed":
                graph.set("window", kAXModalAttribute, NSNumber(value: 2))
                graph.set("window", kAXRoleAttribute, String(repeating: "x", count: 129) as NSString)
                graph.set("window", kAXSubroleAttribute, NSNumber(value: 1))
                graph.set("window", kAXTitleAttribute, NSNumber(value: 1))
            case "secure": graph.set("window", kAXSubroleAttribute, kAXSecureTextFieldSubrole as NSString)
            case "protected": graph.set("window", "AXProtectedContent", kCFBooleanTrue)
            case "hidden": graph.set("window", "AXHidden", kCFBooleanTrue)
            default: break
            }
            let catalog = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: bounds, windowBounds: bounds,
                access: graph.access, mayAct: { true }))
            if ["secure", "protected", "hidden"].contains(mode) {
                XCTAssertTrue(catalog.jsonObject["window"] is NSNull, mode)
                XCTAssertTrue(catalog.items.isEmpty)
                XCTAssertEqual(graph.readCount("window", kAXTitleAttribute), 0)
            } else {
                let window = try XCTUnwrap(catalog.jsonObject["window"] as? [String: Any])
                XCTAssertEqual(window["truncated"] as? Bool, true)
                if mode == "long-title" {
                    XCTAssertEqual(window["title"] as? String, String(repeating: "👩🏽‍💻", count: 25))
                } else {
                    for key in ["role", "subrole", "title", "modal"] { XCTAssertTrue(window[key] is NSNull, key) }
                }
            }
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeWindowContextRejectsMetadataChangesDuringObservation() throws {
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute, kAXModalAttribute, kAXTitleAttribute, "AXProtectedContent", "AXHidden"] {
            let graph = AXTextGraph(), bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
            graph.setFrame("window", bounds); graph.setFrame("destination", CGRect(x: 20, y: 70, width: 200, height: 20))
            graph.set("window", kAXTitleAttribute, "café" as NSString)
            graph.afterRead = { node, name in
                guard node == "destination", name == kAXTitleAttribute else { return }
                if [kAXModalAttribute, "AXProtectedContent", "AXHidden"].contains(attribute) {
                    graph.set("window", attribute, kCFBooleanTrue)
                } else { graph.set("window", attribute, (attribute == kAXTitleAttribute ? "cafe\u{301}" : "AXChanged") as NSString) }
            }
            XCTAssertNil(try ComputerUseNativeControlReader.observe(displayBounds: bounds, windowBounds: bounds,
                access: graph.access, mayAct: { true }), attribute)
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeWindowContextRejectsWithdrawalDuringTheLastAXReply() throws {
        for mode in ["permission", "deadline", "application"] {
            let graph = AXTextGraph(), bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
            graph.setFrame("window", bounds)
            var allowed = true, expired = false
            graph.afterRead = { node, attribute in
                guard node == "window", attribute == kAXModalAttribute, graph.readCount(node, attribute) == 2 else { return }
                switch mode {
                case "permission": allowed = false
                case "deadline": expired = true
                default: graph.applicationIdentity = "replacement-launch"
                }
            }
            let observe = { try ComputerUseNativeControlReader.observe(displayBounds: bounds, windowBounds: bounds,
                access: graph.access, mayAct: { allowed }, now: { Date(timeIntervalSinceReferenceDate: expired ? 1 : 0) }) }
            if mode == "permission" { XCTAssertThrowsError(try observe()) } else { XCTAssertNil(try observe(), mode) }
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeControlCatalogueUsesBoundsAndNeverReadsEditableValues() throws {
        let graph = AXTextGraph()
        let display = CGRect(x: -1280, y: -200, width: 1280, height: 800)
        let window = CGRect(x: -1100, y: -100, width: 900, height: 600)
        graph.setFrame("window", window)
        graph.setFrame("destination", CGRect(x: -1000, y: 50, width: 500, height: 18))
        graph.setFrame("source", CGRect(x: -1000, y: 100, width: 500, height: 24))
        let catalog = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: display, windowBounds: window, access: graph.access, mayAct: { true }))
        XCTAssertEqual(catalog.items.count, 2); XCTAssertFalse(catalog.truncated)
        XCTAssertEqual(catalog.items[0].description, "AXTextField • café")
        XCTAssertEqual(catalog.items[0].bounds1000, [218.75, 312.5, 390.625, 22.5])
        XCTAssertNil(catalog.items[0].enabled, "Missing AXEnabled is unknown, not disabled")
        for name in ["source", "destination"] {
            XCTAssertEqual(graph.readCount(name, kAXValueAttribute), 0)
            XCTAssertEqual(graph.readCount(name, kAXSelectedTextRangeAttribute), 0)
        }
        XCTAssertTrue(graph.writes.isEmpty)
        graph.set("destination", kAXTitleAttribute, String(repeating: "👩🏽‍💻", count: 80) as NSString)
        let clipped = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: display, windowBounds: window, access: graph.access, mayAct: { true }))
        XCTAssertTrue(clipped.truncated, "A clipped label must not look like a complete observation")
        XCTAssertEqual(clipped.items[0].description, "AXTextField • " + String(repeating: "👩🏽‍💻", count: 25))
    }

    func testNativeControlCatalogueExcludesProtectedHiddenAndOffWindowControls() throws {
        for mode in ["secure", "protected", "hidden", "outside", "nonfinite", "disabled-parent"] {
            let graph = AXTextGraph(), window = CGRect(x: 0, y: 0, width: 800, height: 600)
            graph.setFrame("window", window); graph.setFrame("source", CGRect(x: 20, y: 30, width: 200, height: 20))
            graph.setFrame("destination", CGRect(x: 20, y: 70, width: 200, height: 20))
            switch mode {
            case "secure": graph.set("group", kAXSubroleAttribute, kAXSecureTextFieldSubrole as NSString)
            case "protected": graph.set("destination", "AXProtectedContent", kCFBooleanTrue)
            case "hidden": graph.set("destination", "AXHidden", kCFBooleanTrue)
            case "outside": graph.setFrame("destination", CGRect(x: 780, y: 50, width: 100, height: 20))
            case "nonfinite": graph.setFrame("destination", CGRect(x: CGFloat.infinity, y: 50, width: 100, height: 20))
            default: graph.set("group", kAXEnabledAttribute, kCFBooleanFalse)
            }
            let catalog = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: window, windowBounds: window, access: graph.access, mayAct: { true }))
            XCTAssertEqual(catalog.items.count, mode == "secure" ? 0 : (mode == "disabled-parent" ? 2 : 1), mode)
            if mode == "disabled-parent" { XCTAssertTrue(catalog.items.allSatisfy { $0.enabled == false }) }
            if ["secure", "protected", "hidden"].contains(mode) { XCTAssertEqual(graph.readCount("destination", kAXTitleAttribute), 0) }
            XCTAssertEqual(graph.readCount("destination", kAXValueAttribute), 0); XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeControlCatalogueRejectsChangedScopeAndWithdrawnPermission() throws {
        for mode in ["application", "window", "bounds", "permission", "deadline"] {
            let graph = AXTextGraph(), window = CGRect(x: 0, y: 0, width: 800, height: 600)
            graph.setFrame("window", window); graph.setFrame("destination", CGRect(x: 20, y: 70, width: 200, height: 20))
            var allowed = true, expired = false
            graph.afterRead = { node, attribute in
                guard node == "destination", attribute == kAXTitleAttribute else { return }
                switch mode {
                case "application": graph.applicationIdentity = "different-launch"
                case "window": graph.set("application", kAXFocusedWindowAttribute, graph.element("other-window"))
                case "bounds": graph.setFrame("window", window.offsetBy(dx: 20, dy: 0))
                case "permission": allowed = false
                default: expired = true
                }
            }
            let observe = { try ComputerUseNativeControlReader.observe(displayBounds: window, windowBounds: window, access: graph.access,
                mayAct: { allowed }, now: { Date(timeIntervalSinceReferenceDate: expired ? 1 : 0) }) }
            if mode == "permission" { XCTAssertThrowsError(try observe()) }
            else { XCTAssertNil(try observe(), mode) }
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeControlCatalogueBoundsCyclesItemsAndCancellation() async throws {
        for buttons in [true, false] {
            let graph = AXTextGraph(), window = CGRect(x: 0, y: 0, width: 800, height: 600)
            graph.setFrame("window", window)
            var children: [AXUIElement] = [graph.element("window")]
            for index in 0..<140 {
                let name = "item-\(index)"; children.append(graph.addNode(name))
                graph.set(name, kAXRoleAttribute, (buttons ? "AXButton" : "AXGroup") as NSString)
                graph.set(name, kAXTitleAttribute, (String(repeating: "👩🏽‍💻", count: 80) + " instruction text") as NSString)
                graph.setFrame(name, CGRect(x: 20, y: 30, width: 100, height: 20))
            }
            graph.set("window", kAXChildrenAttribute, children as CFArray)
            let catalog = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: window, windowBounds: window, access: graph.access, mayAct: { true }))
            XCTAssertTrue(catalog.truncated); XCTAssertEqual(catalog.items.count, buttons ? 16 : 0)
            XCTAssertTrue(catalog.items.allSatisfy { $0.description.utf8.count <= 512 })
            XCTAssertLessThanOrEqual(graph.calls.filter { $0.operation == "timeout" }.count, 98)
            XCTAssertTrue(graph.writes.isEmpty)
        }
        let graph = AXTextGraph(), window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let task = Task { @MainActor in try ComputerUseNativeControlReader.observe(displayBounds: window, windowBounds: window, access: graph.access, mayAct: { true }) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(graph.calls.isEmpty)
    }

    private func nativeControlsPriorityFixture(nestedUsefulControl: Bool = false) -> (AXTextGraph, CGRect) {
        let graph = AXTextGraph(), window = CGRect(x: 0, y: 0, width: 900, height: 700)
        graph.setFrame("window", window)
        var chrome: [AXUIElement] = []
        for index in 0..<100 {
            let name = "chrome-button-\(index)"
            let element = graph.addNode(name)
            chrome.append(element)
            graph.set(name, kAXRoleAttribute, kAXButtonRole as NSString)
            graph.set(name, kAXTitleAttribute, "Browser control \(index)" as NSString)
            graph.set(name, kAXParentAttribute, graph.element("window"))
            graph.setFrame(name, CGRect(x: 10, y: 10 + CGFloat(index % 20) * 24, width: 140, height: 20))
        }
        let address = graph.addNode("browser-address")
        graph.set("browser-address", kAXRoleAttribute, kAXTextFieldRole as NSString)
        graph.set("browser-address", kAXTitleAttribute, "Browser address" as NSString)
        graph.set("browser-address", kAXValueAttribute, "" as NSString)
        graph.set("browser-address", "AXEditable", kCFBooleanTrue)
        graph.set("browser-address", kAXParentAttribute, graph.element("window"))
        graph.setFrame("browser-address", CGRect(x: 20, y: 410, width: 500, height: 24))
        graph.setSelection("browser-address", NSRange(location: 0, length: 0))
        _ = graph.addNode("web-area")
        graph.set("web-area", kAXRoleAttribute, "AXWebArea" as NSString)
        graph.set("web-area", kAXDocumentAttribute, "https://example.test/" as NSString)
        _ = graph.addNode("page-container")
        graph.set("page-container", kAXRoleAttribute, kAXGroupRole as NSString)
        graph.set("page-container", kAXParentAttribute, graph.element("window"))
        graph.set("page-container", kAXChildrenAttribute, [graph.element("web-area")] as CFArray)
        graph.setFrame("page-container", CGRect(x: 0, y: 450, width: 900, height: 240))
        graph.set("web-area", kAXParentAttribute, graph.element("page-container"))
        graph.setFrame("web-area", CGRect(x: 0, y: 450, width: 900, height: 240))
        _ = graph.addNode("header-shell")
        graph.set("header-shell", kAXRoleAttribute, kAXGroupRole as NSString)
        graph.set("header-shell", kAXParentAttribute, graph.element("web-area"))
        _ = graph.addNode("header-inner")
        graph.set("header-inner", kAXRoleAttribute, kAXGroupRole as NSString)
        graph.set("header-inner", kAXParentAttribute, graph.element("header-shell"))
        graph.set("destination", kAXRoleAttribute, kAXTextFieldRole as NSString)
        graph.set("destination", kAXTitleAttribute, "Search term" as NSString)
        graph.set("destination", kAXValueAttribute, "" as NSString)
        graph.set("destination", "AXEditable", kCFBooleanTrue)
        graph.set("destination", kAXParentAttribute, graph.element("header-inner"))
        graph.setFrame("destination", CGRect(x: 240, y: 480, width: 300, height: 24))
        graph.setSelection("destination", NSRange(location: 0, length: 0))
        let useful = graph.addNode("useful-page-control")
        graph.set("useful-page-control", kAXRoleAttribute, kAXButtonRole as NSString)
        graph.set("useful-page-control", kAXTitleAttribute, "Continue" as NSString)
        graph.setFrame("useful-page-control", CGRect(x: 600, y: 480, width: 120, height: 28))
        if nestedUsefulControl {
            let nested = graph.addNode("nested-web-area")
            graph.set("nested-web-area", kAXRoleAttribute, "AXWebArea" as NSString)
            graph.set("nested-web-area", kAXParentAttribute, graph.element("header-inner"))
            graph.set("nested-web-area", kAXChildrenAttribute, [useful] as CFArray)
            graph.set("useful-page-control", kAXParentAttribute, nested)
            graph.set("header-inner", kAXChildrenAttribute, [graph.element("destination"), nested] as CFArray)
        } else {
            graph.set("useful-page-control", kAXParentAttribute, graph.element("header-inner"))
            graph.set("header-inner", kAXChildrenAttribute, [graph.element("destination"), useful] as CFArray)
        }
        graph.set("header-shell", kAXChildrenAttribute, [graph.element("header-inner")] as CFArray)
        let pageToolbar = graph.addNode("page-toolbar")
        graph.set("page-toolbar", kAXRoleAttribute, kAXGroupRole as NSString)
        graph.set("page-toolbar", kAXParentAttribute, graph.element("web-area"))
        var laterPageControls: [AXUIElement] = []
        for index in 0..<20 {
            let name = "page-control-\(index)"
            let control = graph.addNode(name)
            laterPageControls.append(control)
            graph.set(name, kAXRoleAttribute, kAXButtonRole as NSString)
            graph.set(name, kAXTitleAttribute, "Page control \(index)" as NSString)
            graph.set(name, kAXParentAttribute, pageToolbar)
            graph.setFrame(name, CGRect(x: 250 + CGFloat(index % 5) * 80,
                y: 520 + CGFloat(index / 5) * 30, width: 70, height: 24))
        }
        graph.set("page-toolbar", kAXChildrenAttribute, laterPageControls as CFArray)
        graph.set("web-area", kAXChildrenAttribute, [graph.element("header-shell"), pageToolbar] as CFArray)
        graph.set("window", kAXChildrenAttribute, (chrome + [address, graph.element("page-container")]) as CFArray)
        graph.focused = "destination"
        return (graph, window)
    }

    func testNativeControlsPrioritizeFocusedDocumentAndKeepFocusedChromeEditor() throws {
        let (graph, window) = nativeControlsPriorityFixture()
        let pageFocused = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: window,
            windowBounds: window, access: graph.access, mayAct: { true }))
        let pageIndex = try XCTUnwrap(pageFocused.items.firstIndex { $0.description == "AXButton • Continue" })
        if let chromeIndex = pageFocused.items.firstIndex(where: { $0.description == "AXButton • Browser control 0" }) {
            XCTAssertLessThan(pageIndex, chromeIndex)
        }
        XCTAssertLessThanOrEqual(pageFocused.items.count, 16)
        XCTAssertTrue(pageFocused.truncated)
        XCTAssertLessThanOrEqual(graph.calls.filter { $0.operation == "timeout" }.count, 96)
        XCTAssertTrue(graph.writes.isEmpty)

        graph.focused = "browser-address"
        let chromeChildren = (0..<100).map { graph.element("chrome-button-\($0)") }
        graph.set("window", kAXChildrenAttribute,
            ([graph.element("browser-address")] + chromeChildren + [graph.element("page-container")]) as CFArray)
        graph.calls.removeAll()
        let chromeFocused = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: window,
            windowBounds: window, access: graph.access, mayAct: { true }))
        let addressIndex = try XCTUnwrap(chromeFocused.items.firstIndex { $0.description == "AXTextField • Browser address" })
        let firstChromeIndex = try XCTUnwrap(chromeFocused.items.firstIndex { $0.description == "AXButton • Browser control 0" })
        XCTAssertLessThan(addressIndex, firstChromeIndex)
        XCTAssertLessThanOrEqual(chromeFocused.items.count, 16)
        XCTAssertTrue(graph.writes.isEmpty)
    }

    func testNativeControlFocusedPathKeepsProtectionAndDisabledAncestors() throws {
        for mode in ["hidden", "protected", "secure", "disabled", "nested"] {
            let (graph, window) = nativeControlsPriorityFixture(nestedUsefulControl: mode == "nested")
            switch mode {
            case "hidden": graph.set("page-container", "AXHidden", kCFBooleanTrue)
            case "protected": graph.set("page-container", "AXProtectedContent", kCFBooleanTrue)
            case "secure": graph.set("page-container", kAXSubroleAttribute, kAXSecureTextFieldSubrole as NSString)
            case "disabled": graph.set("page-container", kAXEnabledAttribute, kCFBooleanFalse)
            default: break
            }
            let catalog = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: window,
                windowBounds: window, access: graph.access, mayAct: { true }), mode)
            let useful = catalog.items.first { $0.description == "AXButton • Continue" }
            if ["hidden", "protected", "secure"].contains(mode) {
                XCTAssertNil(useful, mode)
                XCTAssertEqual(catalog.items.first?.description, "AXButton • Browser control 0", mode)
            } else if mode == "disabled" {
                XCTAssertEqual(useful?.enabled, false, "A disabled focused ancestor must remain disabled")
            } else {
                XCTAssertNotNil(useful, "Controls nested under a web area remain in the outer document traversal")
            }
            XCTAssertLessThanOrEqual(catalog.items.count, 16)
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeControlFocusedPathFallsBackOnForeignIncompleteOrCyclicAncestry() throws {
        for mode in ["foreign", "incomplete", "cycle"] {
            let (graph, window) = nativeControlsPriorityFixture()
            switch mode {
            case "foreign": graph.set("page-container", kAXParentAttribute, graph.element("other-window"))
            case "incomplete": graph.set("page-container", kAXParentAttribute, nil)
            default:
                graph.set("page-container", kAXParentAttribute, graph.element("header-shell"))
                graph.set("header-shell", kAXParentAttribute, graph.element("page-container"))
            }
            let catalog = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: window,
                windowBounds: window, access: graph.access, mayAct: { true }), mode)
            XCTAssertEqual(catalog.items.first?.description, "AXButton • Browser control 0", mode)
            XCTAssertFalse(catalog.items.contains { $0.description == "AXButton • Continue" }, mode)
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeControlFocusedPathChangeDuringPrioritizedReadRejectsMixedCatalogue() throws {
        for mode in ["focus", "parent", "hidden-container"] {
            let (graph, window) = nativeControlsPriorityFixture()
            var changed = false
            graph.afterRead = { element, attribute in
                guard !changed, element == "useful-page-control", attribute == kAXTitleAttribute else { return }
                changed = true
                if mode == "focus" { graph.focused = "browser-address" }
                else if mode == "hidden-container" { graph.set("page-container", "AXHidden", kCFBooleanTrue) }
                else { graph.set("page-container", kAXParentAttribute, graph.element("other-group")) }
            }
            XCTAssertNil(try ComputerUseNativeControlReader.observe(displayBounds: window,
                windowBounds: window, access: graph.access, mayAct: { true }), mode)
            XCTAssertTrue(changed, "The useful page control was read before the scope changed")
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeReferenceRejectsSemanticOrParentChangesWithIdenticalValues() throws {
        for change in ["label", "unicode-label", "label-object", "role", "subrole", "identifier", "parent"] {
            let graph = AXTextGraph()
            if change == "label-object" { graph.set("destination", kAXTitleAttribute, nil) }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            switch change {
            case "label": graph.set("destination", kAXTitleAttribute, "Different purpose" as NSString)
            case "unicode-label": graph.set("destination", kAXTitleAttribute, "cafe\u{301}" as NSString)
            case "label-object": graph.set("destination", kAXTitleUIElementAttribute, graph.element("other-label"))
            case "role": graph.set("destination", kAXRoleAttribute, kAXComboBoxRole as NSString)
            case "subrole": graph.set("destination", kAXSubroleAttribute, "AXSearchField" as NSString)
            case "identifier": graph.set("destination", "AXIdentifier", "new-purpose" as NSString)
            default: graph.moveDestination(to: "other-group")
            }
            XCTAssertNil(target.snapshot(targetID: before.targetID), change)
            assertRejected(target, expected: before)
            XCTAssertTrue(graph.writes.isEmpty)
            let changed = try XCTUnwrap(target.snapshot())
            XCTAssertNotEqual(changed.targetID, before.targetID); XCTAssertEqual(changed.value, before.value)
            graph.restoreDestination()
            if change == "label-object" { graph.set("destination", kAXTitleAttribute, nil) }
            let restored = try XCTUnwrap(target.snapshot())
            XCTAssertNotEqual(restored.targetID, before.targetID, "Returning to the original metadata must not revive old authority")
            XCTAssertNil(target.snapshot(targetID: before.targetID))
            assertRejected(target, expected: before)
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testObservedInvalidNativeFieldsCannotReviveOldAuthority() throws {
        for change in ["missing-role", "disabled", "protected", "secure", "invalid-selection", "cycle", "detached"] {
            let graph = AXTextGraph()
            // Construct the production adapter against this graph; no AX IPC
            // occurs through the fixture access boundary.
            let observed = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(observed.snapshot())
            let valueReads = graph.readCount("destination", kAXValueAttribute)
            switch change {
            case "missing-role": graph.set("destination", kAXRoleAttribute, nil)
            case "disabled": graph.set("destination", kAXEnabledAttribute, kCFBooleanFalse)
            case "protected": graph.set("destination", "AXProtectedContent", kCFBooleanTrue)
            case "secure": graph.set("destination", kAXSubroleAttribute, kAXSecureTextFieldSubrole as NSString)
            case "invalid-selection": graph.setSelection("destination", NSRange(location: 100, length: 0))
            case "cycle": graph.set("destination", kAXParentAttribute, graph.element("destination"))
            default: graph.set("destination", kAXParentAttribute, nil)
            }
            XCTAssertNil(observed.snapshot(targetID: before.targetID), change)
            if ["missing-role", "disabled", "protected", "secure"].contains(change) {
                XCTAssertEqual(graph.readCount("destination", kAXValueAttribute), valueReads, "Invalid/protected controls must be rejected before reading their value")
            }
            graph.restoreDestination()
            XCTAssertNil(observed.snapshot(targetID: before.targetID), "Restored visible state cannot revive an observed-invalid reference")
            assertRejected(observed, expected: before)
            XCTAssertTrue(graph.writes.isEmpty)
            let fresh = try XCTUnwrap(observed.snapshot())
            XCTAssertNotEqual(fresh.targetID, before.targetID)
            XCTAssertEqual(try observed.replaceSelectedText("!", expected: fresh), true)
            XCTAssertEqual(graph.value("destination"), "old!")
        }
    }

    func testEditableTextSnapshotAcceptsDeepButBoundedFocusedControlAncestry() throws {
        for referenceCount in [14, 31, 32] {
            let graph = AXTextGraph()
            var groups: [String] = []
            for index in 0 ..< referenceCount - 2 {
                let name = "deep-group-\(index)"
                _ = graph.addNode(name)
                graph.set(name, kAXRoleAttribute, kAXGroupRole as NSString)
                groups.append(name)
            }
            graph.set("destination", kAXParentAttribute, graph.element(groups[0]))
            for index in groups.indices {
                let parent = index + 1 < groups.count ? graph.element(groups[index + 1]) : graph.element("window")
                graph.set(groups[index], kAXParentAttribute, parent)
            }
            let snapshot = ComputerUseAccessibilityTextTarget(access: graph.access).snapshot()
            XCTAssertNotNil(snapshot, "A valid editable field reaching its focused window within \(referenceCount) references must be observable")
            XCTAssertTrue(graph.writes.isEmpty)
        }

        let webGraph = AXTextGraph()
        var webGroups: [String] = []
        for index in 0 ..< 11 {
            let name = "web-group-\(index)"
            _ = webGraph.addNode(name)
            webGraph.set(name, kAXRoleAttribute, kAXGroupRole as NSString)
            webGroups.append(name)
        }
        let webArea = webGraph.addNode("web-area")
        webGraph.set("web-area", kAXRoleAttribute, "AXWebArea" as NSString)
        webGraph.set("web-area", kAXDocumentAttribute, "https://example.test/" as NSString)
        webGraph.set("destination", kAXRoleAttribute, kAXComboBoxRole as NSString)
        webGraph.set("destination", kAXTitleAttribute, "To recipients" as NSString)
        webGraph.set("destination", kAXParentAttribute, webGraph.element(webGroups[0]))
        for index in webGroups.indices {
            let parent = index + 1 < webGroups.count ? webGraph.element(webGroups[index + 1])
                : webArea
            webGraph.set(webGroups[index], kAXParentAttribute, parent)
        }
        webGraph.set("web-area", kAXParentAttribute, webGraph.element("window"))
        XCTAssertNotNil(ComputerUseAccessibilityTextTarget(access: webGraph.access).snapshot(),
            "A deep editable combo inside a web area with a document URL must remain observable")
        XCTAssertTrue(webGraph.writes.isEmpty)
    }

    func testEditableTextSnapshotRejectsOverLimitCyclicDetachedAndForeignAncestry() throws {
        func graphWithAncestors(_ referenceCount: Int) -> (AXTextGraph, [String]) {
            let graph = AXTextGraph()
            var groups: [String] = []
            for index in 0 ..< referenceCount - 2 {
                let name = "bounded-group-\(index)"
                _ = graph.addNode(name)
                graph.set(name, kAXRoleAttribute, kAXGroupRole as NSString)
                groups.append(name)
            }
            graph.set("destination", kAXParentAttribute, graph.element(groups[0]))
            for index in groups.indices {
                let parent = index + 1 < groups.count ? graph.element(groups[index + 1]) : graph.element("window")
                graph.set(groups[index], kAXParentAttribute, parent)
            }
            return (graph, groups)
        }

        let (tooDeep, _) = graphWithAncestors(33)
        XCTAssertNil(ComputerUseAccessibilityTextTarget(access: tooDeep.access).snapshot(), "An ancestry beyond the 32-reference bound must fail closed")

        let (cyclic, cyclicGroups) = graphWithAncestors(14)
        cyclic.set(cyclicGroups.last!, kAXParentAttribute, cyclic.element(cyclicGroups[0]))
        XCTAssertNil(ComputerUseAccessibilityTextTarget(access: cyclic.access).snapshot(), "A cycle must not produce editable authority")

        let (detached, _) = graphWithAncestors(14)
        detached.set("destination", kAXParentAttribute, nil)
        XCTAssertNil(ComputerUseAccessibilityTextTarget(access: detached.access).snapshot(), "A detached field must fail closed")

        let (foreign, foreignGroups) = graphWithAncestors(14)
        _ = foreign.addNode("foreign-window")
        foreign.set("foreign-window", kAXRoleAttribute, kAXWindowRole as NSString)
        foreign.set(foreignGroups.last!, kAXParentAttribute, foreign.element("foreign-window"))
        XCTAssertNil(ComputerUseAccessibilityTextTarget(access: foreign.access).snapshot(), "A field that reaches a different window must fail closed")
        for graph in [tooDeep, cyclic, detached, foreign] { XCTAssertTrue(graph.writes.isEmpty) }
    }

    func testEditableTextSnapshotRejectsAncestryReadThatExceedsDeadline() throws {
        let graph = AXTextGraph()
        graph.afterRead = { element, attribute in
            if element == "destination", attribute == kAXRoleAttribute { Thread.sleep(forTimeInterval: 0.8) }
        }
        let started = ContinuousClock.now
        XCTAssertNil(ComputerUseAccessibilityTextTarget(access: graph.access).snapshot(),
            "A late first AX reply must not produce a text snapshot")
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        XCTAssertTrue(graph.writes.isEmpty)
    }

    func testNativeTypingAndOtherFieldReadsPreserveTheExplicitTarget() throws {
        for web in [false, true] {
            let graph = AXTextGraph()
            if web { graph.set("group", kAXRoleAttribute, "AXWebArea" as NSString) }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let fields = target.fields()
            let before = try XCTUnwrap(fields.first { $0.label == "café" }).snapshot
            let source = try XCTUnwrap(fields.first { $0.label == "Source" }).snapshot
            _ = target.snapshot(targetID: source.targetID)
            XCTAssertTrue(try target.select(NSRange(location: 0, length: 3), expected: before))
            let selected = try XCTUnwrap(target.snapshot())
            XCTAssertEqual(selected.targetID, before.targetID)
            _ = target.snapshot(targetID: source.targetID)
            let applied: Bool?
            if web { applied = try target.replaceWebValue("Paris", expected: selected) }
            else { applied = try target.replaceSelectedText("Paris", expected: selected) }
            XCTAssertEqual(applied, true)
            let after = try XCTUnwrap(target.snapshot())
            XCTAssertEqual(after.targetID, before.targetID); XCTAssertEqual(after.value, "Paris")
            XCTAssertEqual(graph.value("source"), "source text")
            XCTAssertTrue(graph.writes.allSatisfy { $0.element == "destination" })
            let previousWrites = graph.writes.count
            graph.onCapabilityQuery = { [weak graph] in graph?.focused = "source" }
            XCTAssertThrowsError(try target.replaceSelectedText("wrong", expected: after)) {
                XCTAssertEqual($0 as? ComputerUseTextEditError, .preconditionChanged)
            }
            graph.onCapabilityQuery = nil
            XCTAssertEqual(graph.writes.count, previousWrites, "A focus change during capability lookup cannot reach its setter")
            graph.focused = "destination"
            XCTAssertEqual(target.snapshot()?.targetID, before.targetID, "Reading/focusing another intact field is not a structural replacement")
        }
    }

    func testNativePlanningUsesTheLabelBoundByItsSnapshot() throws {
        let graph = AXTextGraph()
        var changed = false
        graph.afterRead = { [weak graph] element, attribute in
            if element == "destination", attribute == kAXTitleAttribute, !changed {
                changed = true
                graph?.set("destination", kAXTitleAttribute, "Changed after observation" as NSString)
            }
        }
        let target = ComputerUseAccessibilityTextTarget(access: graph.access)
        let fields = target.fields()
        let field = try XCTUnwrap(fields.first { $0.snapshot.value == "old" })
        XCTAssertTrue(changed); XCTAssertEqual(field.label, "café")
        XCTAssertNil(target.snapshot(targetID: field.snapshot.targetID))
        assertRejected(target, expected: field.snapshot)
        XCTAssertTrue(graph.writes.isEmpty)
    }

    func testNativePlanningLabelsDoNotReadProtectedOrEditableTitleValues() throws {
        for kind in ["static", "protected", "editable", "secure"] {
            let graph = AXTextGraph()
            graph.set("destination", kAXTitleAttribute, nil)
            if kind != "static" { graph.set("label", kAXValueAttribute, "private title contents" as NSString) }
            if kind == "protected" { graph.set("label", "AXProtectedContent", kCFBooleanTrue) }
            if kind == "editable" || kind == "secure" { graph.set("label", kAXRoleAttribute, kAXTextFieldRole as NSString) }
            if kind == "secure" { graph.set("label", kAXSubroleAttribute, kAXSecureTextFieldSubrole as NSString) }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let field = try XCTUnwrap(target.fields().first { $0.snapshot.value == "old" })
            XCTAssertEqual(field.label, kind == "static" ? "café" : "Focused field")
            XCTAssertEqual(graph.readCount("label", kAXValueAttribute), kind == "static" ? 1 : 0)
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeTaskRejectsRepurposedPlanningTargetAndAcceptsFreshAuthority() async throws {
        let graph = AXTextGraph(), planner = AXGraphPlanner()
        planner.beforeProposal = { [weak graph] in graph?.set("destination", kAXTitleAttribute, "Repurposed field" as NSString) }
        let target = ComputerUseAccessibilityTextTarget(access: graph.access)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = ComputerUseNativeTextExecutor(injector: InputInjector(eventPoster: { _ in XCTFail("AX fixture must not emit keys") }),
            mayAct: { true }, journalDirectory: directory, planner: planner, nativeTarget: target)
        do { _ = try await executor.execute(taskID: "original", prompt: "Apply the requested form edit", progress: { _ in }); XCTFail("The old label cannot authorize a repurposed field") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .staleTarget) }
        XCTAssertTrue(graph.writes.isEmpty); XCTAssertEqual(graph.value("destination"), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        planner.beforeProposal = nil
        for _ in 0..<2 {
            let result = try await executor.execute(taskID: "fresh-request", prompt: "Apply the newly observed form edit", progress: { _ in })
            guard case .completed = result else { return XCTFail("A fresh reviewed target must remain usable") }
        }
        XCTAssertEqual(graph.value("destination"), "Paris"); XCTAssertEqual(graph.value("source"), "source text")
        XCTAssertEqual(graph.writes.filter { $0.attribute == kAXSelectedTextAttribute }.map(\.element), ["destination"])
        XCTAssertEqual(planner.calls, 2)
    }

    func testNativePlanningDeadlineDiscardsLateEditsButAllowsCompiledWorkWithoutAnotherPlanner() async throws {
        let graph = AXTextGraph(), planner = AXClarificationPlanner(), worker = ComputerUsePlanningWorker()
        let gate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "planner started"),
                                                    returned: expectation(description: "planner returned"))
        defer { gate.finish(()) }
        planner.beforeProposal = { _, fields in
            let destination = try XCTUnwrap(fields.first { $0.label == "café" })
            let proposal = ComputerUseTextGoalProposal.edits([
                .init(targetID: destination.snapshot.targetID, mode: .replaceAll, text: "blue")
            ], unchangedTargetIDs: fields.filter { $0.label != "café" }.map { $0.snapshot.targetID })
            await gate.wait()
            return proposal
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory,
            planningWorker: worker, planningTimeout: 0.1)
        do { _ = try await executor.execute(taskID: "late", prompt: "Put \"blue\" in café.", progress: { _ in }); XCTFail("The planner must time out") }
        catch { XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .timedOut) }
        await fulfillment(of: [gate.started], timeout: 1)
        XCTAssertTrue(graph.writes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        do { _ = try await executor.execute(taskID: "busy", prompt: "Put \"blue\" in café.", progress: { _ in }); XCTFail("No second planner may start") }
        catch { XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .busy) }
        XCTAssertEqual(planner.goals.count, 1)
        var compiledResult: ComputerUseExecutionResult?
        var compiledFailure: Error?
        do {
            compiledResult = try await executor.execute(taskID: "compiled", prompt: "Set \"café\" to \"green\".", progress: { _ in })
        } catch { compiledFailure = error }
        gate.finish(())
        await fulfillment(of: [gate.returned], timeout: 1)
        try await waitForAvailablePlanningWorker(worker)
        if let compiledFailure { return XCTFail("Compiled task failed before cleanup: \(compiledFailure)") }
        guard case .completed = compiledResult else {
            return XCTFail("An exact compiled task must not depend on planning capacity")
        }
        XCTAssertEqual(graph.value("destination"), "green", "The stale blue proposal cannot overwrite a later authorized edit")
        XCTAssertEqual(planner.goals.count, 1)
        XCTAssertEqual(graph.writes.filter { $0.attribute == kAXSelectedTextAttribute }.count, 1)
    }

    func testNativeClarificationPlanningDeadlineRetainsExactAnswerOwnershipAndFreshRetry() async throws {
        let graph = AXTextGraph(), planner = AXClarificationPlanner(), worker = ComputerUsePlanningWorker()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory,
            planningWorker: worker, planningTimeout: 0.1)
        _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in the correct field.", progress: { _ in })
        let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
        let answer = try pending.goal.answering(pending.question, with: "Use café.")
        let gate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "answer planner started"),
                                                    returned: expectation(description: "answer planner returned"))
        defer { gate.finish(()) }
        planner.beforeProposal = { _, _ in await gate.wait(); return nil }
        do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("Answer planning must time out") }
        catch { XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .timedOut) }
        await fulfillment(of: [gate.started], timeout: 1)
        XCTAssertNil(try executor.clarification(taskID: "question"))
        XCTAssertTrue(graph.writes.isEmpty)
        do { _ = try await executor.continueClarification(taskID: "other-answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("The expired proposal cannot transfer answer ownership") }
        catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
        do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("An exact retry must still wait for the old call") }
        catch { XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .busy) }
        gate.finish(())
        await fulfillment(of: [gate.returned], timeout: 1)
        try await waitForAvailablePlanningWorker(worker)
        planner.beforeProposal = nil
        graph.set("source", kAXValueAttribute, "fresh source" as NSString)
        graph.set("destination", kAXValueAttribute, "fresh destination" as NSString)
        for _ in 0..<2 {
            guard case .completed = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }) else {
                return XCTFail("The same answer must remain resumable and replay without another edit")
            }
        }
        XCTAssertEqual(planner.goals, [pending.goal, answer, answer])
        XCTAssertEqual(planner.observations.last?.first { $0.label == "café" }?.snapshot.value, "fresh destination")
        XCTAssertEqual(graph.value("destination"), "blue")
        XCTAssertEqual(graph.value("source"), "fresh source")
        XCTAssertEqual(graph.writes.filter { $0.attribute == kAXSelectedTextAttribute }.count, 1)
    }

    func testNativeClarificationDeadlineDoesNotRenewExpiryOrAuthorizeChangedScope() async throws {
        for invalidation in ["expiry", "scope"] {
            let graph = AXTextGraph(), planner = AXClarificationPlanner(), worker = ComputerUsePlanningWorker()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var now = Date(timeIntervalSince1970: 1_000)
            let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory, now: { now },
                planningWorker: worker, planningTimeout: 0.1)
            _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in the correct field.", progress: { _ in })
            let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
            let answer = try pending.goal.answering(pending.question, with: "café")
            let gate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "planner started \(invalidation)"),
                                                        returned: expectation(description: "planner returned \(invalidation)"))
            defer { gate.finish(()) }
            planner.beforeProposal = { _, _ in await gate.wait(); return nil }
            do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("Planning must time out") }
            catch { XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .timedOut) }
            await fulfillment(of: [gate.started], timeout: 1)
            gate.finish(())
            await fulfillment(of: [gate.returned], timeout: 1)
            try await waitForAvailablePlanningWorker(worker)
            planner.beforeProposal = nil
            if invalidation == "expiry" { now = pending.expiresAt.addingTimeInterval(1) }
            else { graph.set("destination", kAXTitleAttribute, "Changed purpose" as NSString) }
            do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("A retry cannot renew expired or changed authority") }
            catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
            XCTAssertEqual(planner.goals.count, 2)
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeClarificationPreservesExactGoalAndReferencesWithFreshValuesAndNoReplay() async throws {
        let graph = AXTextGraph(), planner = AXClarificationPlanner()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var allowed = true
        let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory, mayAct: { allowed })
        let prompt = "Put \"  blue\ncafe\u{301} 🧭  \" in the correct field."
        guard case .clarificationRequired = try await executor.execute(taskID: "question", prompt: prompt, progress: { _ in }) else {
            return XCTFail("An unresolved native form needs a retained question")
        }
        let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
        let answer = try pending.goal.answering(pending.question, with: "  Use the café field.  ")
        XCTAssertTrue(pending.goal.userTurns[0].utf8.elementsEqual(prompt.utf8))
        XCTAssertTrue(graph.writes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        graph.set("source", kAXValueAttribute, "fresh source" as NSString)
        graph.set("destination", kAXValueAttribute, "fresh destination" as NSString)
        graph.setSelection("destination", NSRange(location: 2, length: 0))
        graph.focused = "source"
        allowed = false
        XCTAssertEqual(try executor.clarification(taskID: "question"), pending, "Read-only scope checks remain available while paused")
        do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("Paused input is forbidden") }
        catch { XCTAssertEqual(error as? ComputerUseTextEditError, .interrupted) }
        XCTAssertTrue(graph.writes.isEmpty)
        allowed = true
        for _ in 0..<2 {
            guard case .completed = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }) else {
                return XCTFail("The exact native answer should complete and replay without another edit")
            }
        }
        XCTAssertEqual(planner.goals, [pending.goal, answer])
        XCTAssertEqual(planner.observations[0].map { $0.snapshot.targetID }, planner.observations[1].map { $0.snapshot.targetID })
        XCTAssertEqual(planner.observations[1].first { $0.label == "Source" }?.snapshot.value, "fresh source")
        XCTAssertEqual(planner.observations[1].first { $0.label == "café" }?.snapshot.selection, NSRange(location: 2, length: 0))
        XCTAssertTrue(try XCTUnwrap(graph.value("destination")).utf8.elementsEqual("  blue\ncafe\u{301} 🧭  ".utf8))
        XCTAssertEqual(graph.value("source"), "fresh source")
        XCTAssertEqual(graph.writes.filter { $0.attribute == kAXSelectedTextAttribute }.map(\.element), ["destination"])
        XCTAssertNil(try executor.clarification(taskID: "question"))
        XCTAssertNil(try executor.clarification(taskID: "answer"))
    }

    func testNativeClarificationRejectsChangedScopeAndCannotReviveItAfterRestoration() async throws {
        for change in ["application", "missing-application", "window", "document", "label", "unicode-label",
                       "role", "parent", "protected", "removed", "added", "replacement"] {
            let graph = AXTextGraph(), planner = AXClarificationPlanner()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory)
            _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in the correct field.", progress: { _ in })
            let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
            let answer = try pending.goal.answering(pending.question, with: "café")
            switch change {
            case "application": graph.applicationIdentity = "different-process-launch"
            case "missing-application": graph.applicationAvailable = false
            case "window": graph.set("application", kAXFocusedWindowAttribute, graph.element("other-window"))
            case "document": graph.set("window", kAXDocumentAttribute, "different-document" as NSString)
            case "label": graph.set("destination", kAXTitleAttribute, "Different purpose" as NSString)
            case "unicode-label": graph.set("destination", kAXTitleAttribute, "cafe\u{301}" as NSString)
            case "role": graph.set("destination", kAXRoleAttribute, kAXComboBoxRole as NSString)
            case "parent": graph.moveDestination(to: "other-group")
            case "protected": graph.set("destination", "AXProtectedContent", kCFBooleanTrue)
            case "removed": graph.set("group", kAXChildrenAttribute, [graph.element("source")] as CFArray)
            case "added": graph.addField("replacement", label: "café")
            default:
                graph.addField("replacement", label: "café")
                graph.set("group", kAXChildrenAttribute, [graph.element("replacement"), graph.element("source")] as CFArray)
            }
            do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("Changed scope must reject: \(change)") }
            catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification, change) }
            graph.applicationIdentity = "fixture-process-launch"; graph.applicationAvailable = true
            graph.set("application", kAXFocusedWindowAttribute, graph.element("window"))
            graph.set("window", kAXDocumentAttribute, nil); graph.restoreDestination()
            XCTAssertNil(try executor.clarification(taskID: "question"), change)
            do { _ = try await executor.continueClarification(taskID: "later-answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("Restored appearance cannot restore a consumed clarification") }
            catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
            XCTAssertEqual(planner.goals.count, 1); XCTAssertTrue(graph.writes.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testNativeClarificationRejectsFormDriftWhilePlanningQuestionsOrEdits() async throws {
        for stage in ["initial-question", "answer-question", "answer-edit"] {
            let graph = AXTextGraph(), planner = AXClarificationPlanner()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory)
            planner.beforeProposal = { goal, _ in
                if (goal.userTurns.count == 1) == (stage == "initial-question") {
                    graph.addField("replacement", label: "café")
                    if stage != "answer-edit" { return .clarification }
                }
                return nil
            }
            do {
                _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in the correct field.", progress: { _ in })
                let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
                _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question",
                    goal: pending.goal.answering(pending.question, with: "café"), progress: { _ in })
                XCTFail("A field added during planning cannot change the meaning of a retained question")
            } catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification, stage) }
            XCTAssertNil(try executor.clarification(taskID: "question")); XCTAssertNil(try executor.clarification(taskID: "answer"))
            XCTAssertEqual(planner.goals.count, stage == "initial-question" ? 1 : 2)
            XCTAssertTrue(graph.writes.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testNativeClarificationBindsCancelledPlanningToOneExactAnswerTask() async throws {
        let graph = AXTextGraph(), planner = AXClarificationPlanner()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory)
        _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in the correct field.", progress: { _ in })
        let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
        let answer = try pending.goal.answering(pending.question, with: "café")
        let rewritten = try ComputerUseUnresolvedTextGoal(userRequest: "Put \"red\" in the correct field.").answering(pending.question, with: "café")
        for goal in [rewritten, try pending.goal.answering("Forged question", with: "café")] {
            do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: goal, progress: { _ in }); XCTFail("The answer cannot rewrite the unresolved goal") }
            catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
        }
        planner.beforeProposal = { goal, _ in
            if goal.userTurns.count > 1 { throw CancellationError() }
            return nil
        }
        do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("Injected planning cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(try executor.clarification(taskID: "question")); XCTAssertTrue(graph.writes.isEmpty)
        for (task, origin, goal) in [("other-answer", "question", answer), ("answer", "other-origin", answer), ("answer", "question", rewritten)] {
            do { _ = try await executor.continueClarification(taskID: task, originatingTaskID: origin, goal: goal, progress: { _ in }); XCTFail("Only the claimed answer may resume") }
            catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
        }
        do { _ = try await executor.execute(taskID: "answer", prompt: "Start another edit", progress: { _ in }); XCTFail("A fresh request cannot reuse a prepared answer ID") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .journalMismatch) }
        planner.beforeProposal = nil
        guard case .completed = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }) else {
            return XCTFail("The original answer must remain resumable")
        }
        XCTAssertEqual(planner.goals, [pending.goal, answer, answer])
        XCTAssertEqual(graph.writes.filter { $0.attribute == kAXSelectedTextAttribute }.count, 1)
    }

    func testNativeClarificationExpiryAndInvalidationDuringPlanningCannotIssueNewAuthority() async throws {
        for invalidation in ["expiry", "scope-expiry", "observation-expiry", "explicit"] {
            for outcome in ["question", "unsupported", "edits"] {
                let graph = AXTextGraph(), planner = AXClarificationPlanner()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                var currentTime = Date(timeIntervalSince1970: 1_000)
                let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory, now: { currentTime })
                _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in the correct field.", progress: { _ in })
                let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
                let answer = try pending.goal.answering(pending.question, with: "café")
                if invalidation == "observation-expiry" {
                    var discoveries = 0
                    graph.afterRead = { element, attribute in
                        guard element == "window", attribute == kAXChildrenAttribute else { return }
                        discoveries += 1
                        // Pending scope, prepared scope, then fresh values.
                        if discoveries == 3 { currentTime = pending.expiresAt }
                    }
                }
                planner.beforeProposal = { goal, _ in
                    guard goal.userTurns.count > 1 else { return nil }
                    if invalidation == "expiry" { currentTime = pending.expiresAt }
                    else if invalidation == "scope-expiry" {
                        graph.afterRead = { _, _ in currentTime = pending.expiresAt }
                    } else { executor.invalidateClarification(taskID: "answer") }
                    switch outcome {
                    case "question": return .clarification
                    case "unsupported": return .unsupported
                    default: return nil
                    }
                }
                do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("Invalidation applies to every planner outcome") }
                catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
                // Release the fixture callback's executor capture.
                planner.beforeProposal = nil
                XCTAssertNil(try executor.clarification(taskID: "question")); XCTAssertNil(try executor.clarification(taskID: "answer"))
                XCTAssertEqual(planner.goals.count, invalidation == "observation-expiry" ? 1 : 2)
                XCTAssertTrue(graph.writes.isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            }
        }
    }

    func testNativeClarificationRetainsScopeAcrossQuestionsAndStopsAtTheTurnLimit() async throws {
        let graph = AXTextGraph(), planner = AXClarificationPlanner()
        planner.beforeProposal = { _, _ in .clarification }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory)
        _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in the correct field.", progress: { _ in })
        var pending = try XCTUnwrap(executor.clarification(taskID: "question"))
        let originalScope = pending.scope
        for index in 1..<ComputerUseUnresolvedTextGoal.maximumUserTurns {
            let taskID = "answer-\(index)"
            let goal = try pending.goal.answering(pending.question, with: "  More detail \(index)  ")
            let result = try await executor.continueClarification(taskID: taskID, originatingTaskID: pending.taskID, goal: goal, progress: { _ in })
            XCTAssertNil(try executor.clarification(taskID: pending.taskID))
            if index == ComputerUseUnresolvedTextGoal.maximumUserTurns - 1 {
                guard case .unableToComplete = result else { return XCTFail("The bounded goal must stop asking questions") }
                XCTAssertNil(try executor.clarification(taskID: taskID))
            } else {
                guard case .clarificationRequired = result else { return XCTFail("A supported follow-up must retain its form") }
                let calls = planner.goals.count
                _ = try await executor.continueClarification(taskID: taskID, originatingTaskID: pending.taskID, goal: goal, progress: { _ in })
                XCTAssertEqual(planner.goals.count, calls, "Duplicate delivery of a question must not run planning again")
                pending = try XCTUnwrap(executor.clarification(taskID: taskID))
                XCTAssertEqual(pending.goal, goal); XCTAssertEqual(pending.scope, originalScope)
            }
        }
        XCTAssertEqual(planner.goals.count, ComputerUseUnresolvedTextGoal.maximumUserTurns)
        XCTAssertTrue(graph.writes.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testNativeLifecycleEventsRetireSameObjectAuthorityAfterVisibleStateReturns() throws {
        for notification in [kAXTitleChangedNotification, kAXLayoutChangedNotification,
                             kAXFocusedWindowChangedNotification, kAXApplicationDeactivatedNotification,
                             kAXCreatedNotification, kAXRowCountChangedNotification] {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            graph.lifecycleFactory = { _ in monitor }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            // The application has already returned to identical attributes
            // when the next read begins. The delivered event is the evidence.
            monitor.notify(notification as String, element: graph.element("destination"))
            XCTAssertNil(target.snapshot(targetID: before.targetID), notification as String)
            assertRejected(target, expected: before)
            XCTAssertTrue(graph.writes.isEmpty)
            let fresh = try XCTUnwrap(target.snapshot())
            XCTAssertNotEqual(fresh.targetID, before.targetID); XCTAssertEqual(fresh.value, before.value)
            XCTAssertEqual(try target.replaceSelectedText("!", expected: fresh), true)
            XCTAssertEqual(graph.value("destination"), "old!")
        }
    }

    func testDiagnosticObserverReportsBindingCreationAndRetirementWithoutChangingAXAccess() throws {
        struct Run {
            let calls: [AXTextGraph.Call]
            let writes: [AXTextGraph.Write]
            let events: [ComputerUseAccessibilityTextTarget.DiagnosticEvent]
            let targetID: String
        }
        func exercise(observe: Bool) throws -> Run {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            graph.lifecycleFactory = { _ in monitor }
            var events: [ComputerUseAccessibilityTextTarget.DiagnosticEvent] = []
            let diagnosticObserver: (@MainActor (ComputerUseAccessibilityTextTarget.DiagnosticEvent) -> Void)?
            if observe {
                diagnosticObserver = { event in events.append(event) }
            } else {
                diagnosticObserver = nil
            }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access,
                diagnosticObserver: diagnosticObserver)
            let retained = try XCTUnwrap(target.snapshot())
            monitor.notify(kAXTitleChangedNotification as String, element: graph.element("destination"))
            XCTAssertNil(target.snapshot(targetID: retained.targetID))
            XCTAssertTrue(graph.writes.isEmpty)
            return Run(calls: graph.calls, writes: graph.writes, events: events, targetID: retained.targetID)
        }

        let withoutObserver = try exercise(observe: false)
        let withObserver = try exercise(observe: true)
        XCTAssertEqual(withObserver.calls.map { "\($0.element):\($0.operation)" },
                       withoutObserver.calls.map { "\($0.element):\($0.operation)" })
        XCTAssertEqual(withObserver.writes.count, withoutObserver.writes.count)
        XCTAssertTrue(withoutObserver.events.isEmpty)
        XCTAssertEqual(withObserver.events.map(\.kind), ["bindingCreated", "bindingRetired"])
        XCTAssertEqual(withObserver.events.map(\.targetID), [withObserver.targetID, withObserver.targetID])
        let retirement = try XCTUnwrap(withObserver.events.last)
        XCTAssertEqual(retirement.notification, kAXTitleChangedNotification as String)
        XCTAssertTrue(retirement.matchedReferences.contains("field"))
        let encoded = String(decoding: try JSONEncoder().encode(withObserver.events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("café")); XCTAssertFalse(encoded.contains("old"))
    }

    func testUnrelatedElementTitleChangeDuringReadPreservesFocusedFieldAuthority() throws {
        for notification in [kAXTitleChangedNotification, kAXValueChangedNotification] {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            let unrelated = graph.addNode("unrelated")
            graph.set("unrelated", kAXRoleAttribute, kAXButtonRole as NSString)
            graph.lifecycleFactory = { _ in monitor }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            var delivered = false
            graph.afterRead = { element, attribute in
                guard !delivered, element == "destination", attribute == kAXValueAttribute else { return }
                delivered = true
                monitor.notify(notification as String, element: unrelated)
            }
            XCTAssertEqual(target.snapshot(targetID: before.targetID), before, "\(notification) on unrelated button")
            XCTAssertTrue(delivered)
            XCTAssertTrue(graph.writes.isEmpty)
        }
        let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
        graph.lifecycleFactory = { _ in monitor }
        let target = ComputerUseAccessibilityTextTarget(access: graph.access)
        let before = try XCTUnwrap(target.snapshot())
        graph.afterRead = { element, attribute in
            if element == "destination", attribute == kAXValueAttribute {
                monitor.notify(kAXTitleChangedNotification as String, element: graph.element("destination"))
            }
        }
        XCTAssertNil(target.snapshot(targetID: before.targetID), "A title change on the focused field still retires its meaning")
        XCTAssertTrue(graph.writes.isEmpty)
    }

    func testFieldOrAncestorLifecycleEventDuringReadRetiresAuthority() throws {
        let cases: [(String, String, String)] = [
            ("field title", "destination", kAXTitleChangedNotification as String),
            ("ancestor layout", "group", kAXLayoutChangedNotification as String),
            ("label value", "label", kAXValueChangedNotification as String),
            ("root title", "application", kAXTitleChangedNotification as String)
        ]
        for (name, changedElement, notification) in cases {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            if changedElement == "label" { graph.set("destination", kAXTitleAttribute, nil) }
            graph.lifecycleFactory = { _ in monitor }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            var delivered = false
            graph.afterRead = { element, attribute in
                guard !delivered, element == "destination", attribute == kAXValueAttribute else { return }
                delivered = true
                monitor.notify(notification, element: graph.element(changedElement))
            }
            XCTAssertNil(target.snapshot(targetID: before.targetID), name)
            XCTAssertTrue(delivered, name)
            XCTAssertTrue(graph.writes.isEmpty, name)
        }
    }

    func testIntermediateAncestorValueChangeDoesNotRetireUnchangedFocusedField() throws {
        func readTrace(useWebArea: Bool, deliverOnIntermediateAncestor: Bool, duringRead: Bool) throws -> ([String], Bool) {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            if useWebArea {
                _ = graph.addNode("web-area")
                graph.set("web-area", kAXRoleAttribute, "AXWebArea" as NSString)
                graph.set("web-area", kAXParentAttribute, graph.element("window"))
                graph.set("web-area", kAXDocumentAttribute, "https://example.test/" as NSString)
                graph.set("group", kAXParentAttribute, graph.element("web-area"))
            }
            graph.lifecycleFactory = { _ in monitor }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            graph.calls.removeAll()
            var retainedIDSurvived = false
            if deliverOnIntermediateAncestor {
                if duringRead {
                    var delivered = false
                    graph.afterRead = { element, attribute in
                        guard !delivered, element == "destination", attribute == kAXValueAttribute else { return }
                        delivered = true
                        monitor.notify(kAXValueChangedNotification as String, element: graph.element("group"))
                    }
                    let current = target.snapshot(targetID: before.targetID)
                    XCTAssertEqual(current, before)
                    retainedIDSurvived = current?.targetID == before.targetID
                    XCTAssertTrue(delivered)
                } else {
                    monitor.notify(kAXValueChangedNotification as String, element: graph.element("group"))
                    let current = target.snapshot(targetID: before.targetID)
                    XCTAssertEqual(current, before)
                    retainedIDSurvived = current?.targetID == before.targetID
                }
            } else {
                let current = target.snapshot(targetID: before.targetID)
                XCTAssertEqual(current, before)
                retainedIDSurvived = current?.targetID == before.targetID
            }
            XCTAssertTrue(graph.writes.isEmpty)
            return (graph.calls.map { "\($0.element):\($0.operation)" }, retainedIDSurvived)
        }

        for useWebArea in [false, true] {
            let baseline = try readTrace(useWebArea: useWebArea,
                deliverOnIntermediateAncestor: false, duringRead: false)
            for duringRead in [false, true] {
                let observed = try readTrace(useWebArea: useWebArea,
                    deliverOnIntermediateAncestor: true, duringRead: duringRead)
                XCTAssertEqual(observed.0, baseline.0, "Lifecycle classification must not add AX reads")
                XCTAssertTrue(observed.1)
            }
        }
    }

    func testValueChangeOnWindowOrWebDocumentRootStillRetiresFocusedField() throws {
        for useWebArea in [false, true] {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            if useWebArea {
                _ = graph.addNode("web-area")
                graph.set("web-area", kAXRoleAttribute, "AXWebArea" as NSString)
                graph.set("web-area", kAXParentAttribute, graph.element("window"))
                graph.set("web-area", kAXDocumentAttribute, "https://example.test/" as NSString)
                graph.set("group", kAXParentAttribute, graph.element("web-area"))
            }
            graph.lifecycleFactory = { _ in monitor }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            monitor.notify(kAXValueChangedNotification as String,
                           element: graph.element(useWebArea ? "web-area" : "window"))
            XCTAssertNil(target.snapshot(targetID: before.targetID))
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testFocusedFieldValueChangeDuringSnapshotStillRetiresAuthority() throws {
        let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
        graph.lifecycleFactory = { _ in monitor }
        let target = ComputerUseAccessibilityTextTarget(access: graph.access)
        let before = try XCTUnwrap(target.snapshot())
        var delivered = false
        graph.afterRead = { element, attribute in
            guard !delivered, element == "destination", attribute == kAXValueAttribute else { return }
            delivered = true
            graph.set("destination", kAXValueAttribute, "changed" as NSString)
            monitor.notify(kAXValueChangedNotification as String, element: graph.element("destination"))
        }
        XCTAssertNil(target.snapshot(targetID: before.targetID))
        XCTAssertTrue(delivered)
        XCTAssertTrue(graph.writes.isEmpty)
    }

    func testIntermediateValueEventCannotAuthorizeChangedFieldOrUsedLabel() throws {
        for change in ["value", "selection"] {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            graph.lifecycleFactory = { _ in monitor }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            if change == "value" { graph.set("destination", kAXValueAttribute, "changed" as NSString) }
            else { graph.setSelection("destination", NSRange(location: 0, length: 0)) }
            monitor.notify(kAXValueChangedNotification as String, element: graph.element("group"))
            _ = target.snapshot(targetID: before.targetID)
            XCTAssertThrowsError(try target.replaceSelectedText("unsafe", expected: before)) {
                XCTAssertEqual($0 as? ComputerUseTextEditError, .preconditionChanged)
            }
            XCTAssertTrue(graph.writes.isEmpty)
        }
        do {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            graph.set("destination", kAXTitleAttribute, nil)
            graph.set("destination", kAXTitleUIElementAttribute, graph.element("group"))
            graph.set("group", kAXRoleAttribute, kAXStaticTextRole as NSString)
            graph.set("group", kAXValueAttribute, "Recipient" as NSString)
            graph.lifecycleFactory = { _ in monitor }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            monitor.notify(kAXValueChangedNotification as String, element: graph.element("group"))
            XCTAssertNil(target.snapshot(targetID: before.targetID), "A used label remains identity-bearing even when it is an ancestor")
            XCTAssertThrowsError(try target.replaceSelectedText("unsafe", expected: before)) {
                XCTAssertEqual($0 as? ComputerUseTextEditError, .preconditionChanged)
            }
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNilSourceScopeAndCoverageEventsRetireObservation() throws {
        for kind in [ComputerUseAXLifecycleEvent.Kind.scopeChanged, .coverageLost, .elementChanged, .valueChanged] {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            graph.lifecycleFactory = { _ in monitor }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            var delivered = false
            graph.afterRead = { element, attribute in
                guard !delivered, element == "destination", attribute == kAXValueAttribute else { return }
                delivered = true
                monitor.record(.init(kind: kind, element: nil))
            }
            XCTAssertNil(target.snapshot(targetID: before.targetID), "\(kind) with nil source")
            XCTAssertTrue(delivered)
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testFocusChangeDuringInitialFocusedElementLookupRejectsMixedSnapshot() throws {
        let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
        graph.lifecycleFactory = { _ in monitor }
        let target = ComputerUseAccessibilityTextTarget(access: graph.access)
        var delivered = false
        graph.afterRead = { element, attribute in
            guard !delivered, element == "application", attribute == kAXFocusedUIElementAttribute else { return }
            delivered = true
            graph.focused = "source"
            monitor.notify(kAXFocusedWindowChangedNotification as String, element: graph.element("application"))
        }
        XCTAssertNil(target.snapshot(), "Focus changing during the initial focus/window lookup must discard the mixed snapshot")
        XCTAssertTrue(delivered)
        XCTAssertTrue(graph.writes.isEmpty)
    }

    func testScopedLifecycleEventAccumulatorOverflowFailsClosed() throws {
        let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
        let unrelated = graph.addNode("unrelated")
        graph.set("unrelated", kAXRoleAttribute, kAXButtonRole as NSString)
        graph.lifecycleFactory = { _ in monitor }
        let target = ComputerUseAccessibilityTextTarget(access: graph.access)
        let before = try XCTUnwrap(target.snapshot())
        var boundaryCount = 0
        graph.afterRead = { _, _ in
            guard boundaryCount < 9 else { return }
            boundaryCount += 1
            // Each batch is drained at the next AX boundary, so the test covers
            // bounded per-observation accumulation rather than inbox overflow.
            for _ in 0..<32 {
                monitor.notify(kAXTitleChangedNotification as String, element: unrelated)
            }
        }
        XCTAssertNil(target.snapshot(targetID: before.targetID), "Too many distinct lifecycle events in one observation must fail closed")
        XCTAssertGreaterThan(boundaryCount, 8)
        XCTAssertTrue(graph.writes.isEmpty)
    }

    func testUnrelatedNativeCreationPreservesExactFieldAuthorityAcrossInputBoundaries() throws {
        for notification in [kAXCreatedNotification, kAXWindowCreatedNotification] {
            for unrelated in ["other-window", "source", "other-label"] {
                for stage in ["before-read", "during-read", "capability"] {
                    let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
                    graph.lifecycleFactory = { _ in monitor }
                    let target = ComputerUseAccessibilityTextTarget(access: graph.access)
                    let before = try XCTUnwrap(target.snapshot())
                    var delivered = false
                    func deliver() {
                        guard !delivered else { return }
                        delivered = true
                        monitor.notify(notification as String, element: graph.element(unrelated))
                    }
                    if stage == "before-read" { deliver() }
                    else if stage == "during-read" {
                        graph.afterRead = { element, attribute in
                            if element == "destination", attribute == kAXValueAttribute { deliver() }
                        }
                    } else { graph.onCapabilityQuery = { deliver() } }
                    XCTAssertEqual(target.snapshot(targetID: before.targetID), before, "\(notification):\(unrelated):\(stage)")
                    XCTAssertEqual(try target.replaceSelectedText("🗺️ café", expected: before), true)
                    XCTAssertTrue(delivered)
                    XCTAssertEqual(graph.value("destination"), "old🗺️ café")
                    XCTAssertEqual(graph.value("source"), "source text")
                    XCTAssertFalse(graph.calls.contains { $0.element == unrelated }, "Creation handling only compares retained object identity")
                }
            }
        }
    }

    func testRelatedOrUnscopedNativeCreationStillRetiresRetainedAuthority() throws {
        for notification in [kAXCreatedNotification, kAXWindowCreatedNotification] {
            for related in ["destination", "label", "group", "window", "application"] {
                let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
                graph.set("destination", kAXTitleAttribute, nil)
                graph.lifecycleFactory = { _ in monitor }
                let target = ComputerUseAccessibilityTextTarget(access: graph.access)
                let before = try XCTUnwrap(target.snapshot())
                monitor.notify(notification as String, element: graph.element(related))
                XCTAssertNil(target.snapshot(targetID: before.targetID), "\(notification):\(related)")
                assertRejected(target, expected: before)
                XCTAssertTrue(graph.writes.isEmpty)
                XCTAssertNotEqual(try XCTUnwrap(target.snapshot()).targetID, before.targetID)
            }
        }
        let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
        graph.lifecycleFactory = { _ in monitor }
        let target = ComputerUseAccessibilityTextTarget(access: graph.access)
        let before = try XCTUnwrap(target.snapshot())
        monitor.record(.init(kind: .created, element: nil))
        XCTAssertNil(target.snapshot(targetID: before.targetID))
        assertRejected(target, expected: before)
        XCTAssertTrue(graph.writes.isEmpty)
    }

    func testDestroyedNativeObjectsAreNeverQueriedAgainThroughAnyAXBoundary() throws {
        for name in ["destination", "label", "group", "window", "application"] {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            if name == "label" { graph.set("destination", kAXTitleAttribute, nil) }
            graph.lifecycleFactory = { _ in monitor }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            monitor.notify(kAXUIElementDestroyedNotification as String, element: graph.element(name))
            let start = graph.calls.count
            XCTAssertNil(target.snapshot(targetID: before.targetID))
            assertRejected(target, expected: before)
            _ = target.fields(); _ = target.snapshot()
            graph.restoreDestination()
            if name == "label" { graph.set("destination", kAXTitleAttribute, nil) }
            XCTAssertNil(target.snapshot(targetID: before.targetID))
            XCTAssertNil(target.snapshot(), "Retained destroyed objects cannot be revived by readable attributes")
            XCTAssertFalse(graph.calls.dropFirst(start).contains { $0.element == name }, "No read, settable query, timeout or write may use the destroyed \(name)")
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeDestroyedLabelRejectsObservationUntilFreshLabelAuthorityExists() throws {
        let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
        graph.set("destination", kAXTitleAttribute, nil)
        graph.lifecycleFactory = { _ in monitor }
        let target = ComputerUseAccessibilityTextTarget(access: graph.access)
        let before = try XCTUnwrap(target.snapshot())
        monitor.notify(kAXUIElementDestroyedNotification as String, element: graph.element("label"))
        let callCount = graph.calls.count
        XCTAssertNil(target.snapshot())
        assertRejected(target, expected: before)
        XCTAssertFalse(graph.calls.dropFirst(callCount).contains { $0.element == "label" })
        XCTAssertTrue(graph.writes.isEmpty)
        graph.set("destination", kAXTitleUIElementAttribute, graph.element("other-label"))
        let fresh = try XCTUnwrap(target.snapshot())
        XCTAssertNotEqual(fresh.targetID, before.targetID)
        XCTAssertEqual(fresh.value, before.value)
        XCTAssertEqual(try target.replaceSelectedText("!", expected: fresh), true)
        XCTAssertEqual(graph.value("destination"), "old!")
    }

    func testNativeLifecycleDistinguishesTextStateFromLabelMeaning() throws {
        let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
        graph.set("destination", kAXTitleAttribute, nil)
        graph.lifecycleFactory = { _ in monitor }
        let target = ComputerUseAccessibilityTextTarget(access: graph.access)
        let fields = target.fields()
        let destination = try XCTUnwrap(fields.first { $0.label == "café" }).snapshot
        let source = try XCTUnwrap(fields.first { $0.label == "Source" }).snapshot
        graph.set("destination", kAXValueAttribute, "new" as NSString)
        for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXFocusedUIElementChangedNotification] {
            monitor.notify(notification as String, element: graph.element("destination"))
        }
        let edited = try XCTUnwrap(target.snapshot(targetID: destination.targetID))
        XCTAssertEqual(edited.targetID, destination.targetID); XCTAssertEqual(edited.value, "new")
        XCTAssertEqual(target.snapshot(targetID: source.targetID), source)
        monitor.notify(kAXValueChangedNotification as String, element: graph.element("label"))
        XCTAssertNil(target.snapshot(targetID: destination.targetID), "A label changed and reverted; its old meaning cannot be reused")
        XCTAssertEqual(target.snapshot(targetID: source.targetID), source, "An unrelated field's exact identity remains intact")
        let refreshed = try XCTUnwrap(target.snapshot())
        monitor.notify(kAXValueChangedNotification as String, element: graph.element("window"))
        XCTAssertNil(target.snapshot(targetID: refreshed.targetID))
        XCTAssertNil(target.snapshot(targetID: source.targetID), "An enclosing context value is not an ordinary edit to either field")
        XCTAssertTrue(graph.writes.isEmpty)
    }

    func testNativeLifecycleIgnoresUnusedLabelObjectsWithoutReadingTheirValues() throws {
        for titleObject in ["label", "destination"] {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            graph.set("destination", kAXTitleUIElementAttribute, graph.element(titleObject))
            graph.lifecycleFactory = { _ in monitor }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            XCTAssertEqual(graph.readCount("label", kAXValueAttribute), 0, "The explicit title already supplies the planning label")
            monitor.notify(kAXValueChangedNotification as String, element: graph.element(titleObject))
            XCTAssertEqual(target.snapshot(targetID: before.targetID), before)
            if titleObject == "label" {
                monitor.notify(kAXUIElementDestroyedNotification as String, element: graph.element("label"))
                XCTAssertEqual(target.snapshot(targetID: before.targetID), before, "An unused title object carries no edit authority")
            }
            XCTAssertEqual(try target.replaceSelectedText("!", expected: before), true)
            XCTAssertEqual(graph.value("destination"), "old!")
            XCTAssertEqual(graph.readCount("label", kAXValueAttribute), 0)
        }
    }

    func testNativeLifecycleEventsDuringObservationAndCapabilityChecksStopBeforeInput() throws {
        for stage in [kAXValueAttribute, kAXTitleAttribute, "AXIdentifier", "capability"] {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            graph.lifecycleFactory = { _ in monitor }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            var delivered = false
            func deliver() {
                guard !delivered else { return }
                delivered = true
                monitor.notify(kAXLayoutChangedNotification as String, element: graph.element("window"))
            }
            if stage == "capability" { graph.onCapabilityQuery = { deliver() } }
            else { graph.afterRead = { element, attribute in if element == "destination", attribute == stage { deliver() } } }
            if stage == "capability" {
                XCTAssertThrowsError(try target.select(NSRange(location: 0, length: 0), expected: before)) {
                    XCTAssertEqual($0 as? ComputerUseTextEditError, .preconditionChanged)
                }
            } else { XCTAssertNil(target.snapshot(targetID: before.targetID)) }
            XCTAssertTrue(delivered); XCTAssertTrue(graph.writes.isEmpty)
            graph.afterRead = nil; graph.onCapabilityQuery = nil
            assertRejected(target, expected: before)
            XCTAssertNotEqual(try XCTUnwrap(target.snapshot()).targetID, before.targetID)
        }
    }

    func testNativeLifecycleChangesDuringPlanningRejectEditsAndClarificationAnswers() async throws {
        for scenario in ["edit", "clarification"] {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            graph.lifecycleFactory = { _ in monitor }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            if scenario == "edit" {
                let planner = AXGraphPlanner()
                planner.beforeProposal = { monitor.notify(kAXLayoutChangedNotification as String, element: graph.element("window")) }
                let executor = ComputerUseNativeTextExecutor(injector: InputInjector(eventPoster: { _ in XCTFail("No key input") }),
                    mayAct: { true }, journalDirectory: directory, planner: planner,
                    nativeTarget: ComputerUseAccessibilityTextTarget(access: graph.access))
                do { _ = try await executor.execute(taskID: "edit", prompt: "Apply the requested form edit", progress: { _ in }); XCTFail("A lifecycle event must retire planning authority") }
                catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .staleTarget) }
            } else {
                let planner = AXClarificationPlanner()
                let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory)
                _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in the correct field.", progress: { _ in })
                let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
                monitor.notify(kAXTitleChangedNotification as String, element: graph.element("destination"))
                do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question",
                    goal: pending.goal.answering(pending.question, with: "café"), progress: { _ in }); XCTFail("An answer cannot revive pre-event references") }
                catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
                XCTAssertNil(try executor.clarification(taskID: "question")); XCTAssertEqual(planner.goals.count, 1)
            }
            XCTAssertTrue(graph.writes.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testNativeLifecycleOverflowRetiresOldReferencesAndFreshObservationRecovers() throws {
        let graph = AXTextGraph()
        var monitors: [AXFixtureLifecycleMonitor] = []
        graph.lifecycleFactory = { _ in let next = AXFixtureLifecycleMonitor(); monitors.append(next); return next }
        var target: ComputerUseAccessibilityTextTarget? = ComputerUseAccessibilityTextTarget(access: graph.access)
        let first = try XCTUnwrap(target?.snapshot())
        XCTAssertEqual(target?.snapshot()?.targetID, first.targetID); XCTAssertEqual(monitors.count, 1)
        graph.applicationIdentity = "second-launch"
        let second = try XCTUnwrap(target?.snapshot())
        XCTAssertNotEqual(first.targetID, second.targetID); XCTAssertEqual(monitors.count, 2)
        XCTAssertEqual(monitors[0].cancellations, 1)
        monitors[0].notify(kAXUIElementDestroyedNotification as String, element: graph.element("destination"))
        XCTAssertEqual(target?.snapshot(targetID: second.targetID), second, "An old source must not invalidate a replacement scope")
        for _ in 0...ComputerUseAXLifecycleInbox.maximumEvents {
            monitors[1].notify(kAXUIElementDestroyedNotification as String, element: graph.element("other-label"))
        }
        let calls = graph.calls.count
        XCTAssertNil(target?.snapshot(targetID: second.targetID))
        XCTAssertEqual(graph.calls.count, calls, "Lost event coverage must stop all AX queries in this scope")
        let fresh = try XCTUnwrap(target?.snapshot(), "A new observation must be able to establish fresh AX authority")
        XCTAssertNotEqual(fresh.targetID, second.targetID)
        XCTAssertEqual(monitors.count, 3)
        XCTAssertEqual(monitors[1].cancellations, 1)
        XCTAssertNil(target?.snapshot(targetID: second.targetID), "An old reference must never revive")
        monitors[1].notify(kAXUIElementDestroyedNotification as String, element: graph.element("destination"))
        XCTAssertEqual(target?.snapshot(targetID: fresh.targetID), fresh)
        XCTAssertThrowsError(try target?.focus(expected: second))
        XCTAssertTrue(graph.writes.isEmpty)
        target = nil
        XCTAssertEqual(monitors[1].cancellations, 1)
        XCTAssertEqual(monitors[2].cancellations, 1)
    }

    func testNativeLifecycleCallbackRegistryOwnsExactRegistrationAndBoundsItsInbox() throws {
        let callbacks = ComputerUseAXLifecycleCallbacks(), source = NSObject()
        let element = AXUIElementCreateApplication(60_000)
        let first = ComputerUseAXLifecycleInbox(), second = ComputerUseAXLifecycleInbox()
        let oldRegistration = callbacks.register(source: source, inbox: first)
        callbacks.deliver(source: source, element: element, notification: kAXTitleChangedNotification as String)
        XCTAssertEqual(first.drain().map(\.kind), [.elementChanged])
        let replacement = callbacks.register(source: source, inbox: second)
        callbacks.remove(oldRegistration)
        callbacks.deliver(source: source, element: element, notification: kAXUIElementDestroyedNotification as String)
        let event = try XCTUnwrap(second.drain().first)
        XCTAssertEqual(event.kind, .destroyed); XCTAssertTrue(CFEqual(try XCTUnwrap(event.element), element))
        callbacks.deliver(source: source, element: element, notification: "UnknownNotification")
        callbacks.deliver(source: source, element: element, notification: kAXSelectedTextChangedNotification as String)
        XCTAssertTrue(second.drain().isEmpty)
        callbacks.remove(replacement)
        callbacks.deliver(source: source, element: element, notification: kAXLayoutChangedNotification as String)
        second.record(.init(kind: .scopeChanged, element: nil))
        XCTAssertTrue(first.drain().isEmpty); XCTAssertTrue(second.drain().isEmpty)
        let overflow = ComputerUseAXLifecycleInbox()
        for _ in 0...ComputerUseAXLifecycleInbox.maximumEvents { overflow.record(.init(kind: .destroyed, element: element)) }
        XCTAssertEqual(overflow.drain().map(\.kind), [.coverageLost])
        XCTAssertEqual(overflow.drain().map(\.kind), [.coverageLost], "Draining must not erase the fact that a destruction event was lost")
        overflow.close(); XCTAssertTrue(overflow.drain().isEmpty)
    }

    private func clarificationExecutor(graph: AXTextGraph, planner: AXClarificationPlanner, directory: URL,
                                       mayAct: @escaping () -> Bool = { true }, now: @escaping () -> Date = Date.init,
                                       planningWorker: ComputerUsePlanningWorker = ComputerUsePlanningWorker(),
                                       planningTimeout: TimeInterval = ComputerUsePlanningWorker.maximumWait) -> ComputerUseNativeTextExecutor {
        ComputerUseNativeTextExecutor(injector: InputInjector(eventPoster: { _ in XCTFail("The AX fixture must not emit keys") }),
            mayAct: mayAct, journalDirectory: directory, planner: planner, now: now,
            nativeTarget: ComputerUseAccessibilityTextTarget(access: graph.access),
            planningWorker: planningWorker, planningTimeout: planningTimeout)
    }

    private func assertRejected(_ target: ComputerUseAccessibilityTextTarget, expected: ComputerUseTextSnapshot,
                                file: StaticString = #filePath, line: UInt = #line) {
        let operations: [() throws -> Void] = [{ _ = try target.focus(expected: expected) },
            { _ = try target.select(NSRange(location: 0, length: 0), expected: expected) },
            { _ = try target.replaceSelectedText("wrong", expected: expected) },
            { _ = try target.replaceWebValue("wrong", expected: expected) }]
        for operation in operations {
            XCTAssertThrowsError(try operation(), file: file, line: line) {
                XCTAssertEqual($0 as? ComputerUseTextEditError, .preconditionChanged, file: file, line: line)
            }
        }
    }
}

private final class AXProbeLifecycleRecorder: ComputerUseAXLifecycleMonitoring {
    private let underlying: any ComputerUseAXLifecycleMonitoring
    private var focused: AXUIElement
    private var window: AXUIElement
    private var appRoot: AXUIElement
    private var ancestors: [AXUIElement]
    private let lock = NSLock()
    private var activeSample = -1
    private var counts: [EventKey: Int] = [:]

    private struct EventKey: Hashable {
        let sampleIndex: Int
        let kind: String
        let notification: String?
        let elementMatchesFocused: Bool?
        let elementMatchesWindow: Bool?
        let elementMatchesAppRoot: Bool?
        let elementMatchesRetainedAncestor: Bool?
    }

    init(_ underlying: any ComputerUseAXLifecycleMonitoring, focused: AXUIElement, window: AXUIElement,
         appRoot: AXUIElement, ancestors: [AXUIElement]) {
        self.underlying = underlying
        self.focused = focused
        self.window = window
        self.appRoot = appRoot
        self.ancestors = ancestors
    }

    func beginSample(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        activeSample = index
    }

    func updateContext(focused: AXUIElement, window: AXUIElement, appRoot: AXUIElement, ancestors: [AXUIElement]) {
        lock.lock(); defer { lock.unlock() }
        self.focused = focused
        self.window = window
        self.appRoot = appRoot
        self.ancestors = ancestors
    }

    func drain() -> [ComputerUseAXLifecycleEvent] {
        let events = underlying.drain()
        lock.lock()
        for event in events {
            let element = event.element
            let key = EventKey(sampleIndex: activeSample, kind: String(describing: event.kind),
                notification: event.notification,
                elementMatchesFocused: element.map { CFEqual($0, focused) },
                elementMatchesWindow: element.map { CFEqual($0, window) },
                elementMatchesAppRoot: element.map { CFEqual($0, appRoot) },
                elementMatchesRetainedAncestor: element.map { item in ancestors.contains(where: { CFEqual($0, item) }) })
            counts[key, default: 0] += 1
        }
        lock.unlock()
        return events
    }

    func takeCapturedEvents() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let summary = counts.map { key, count -> [String: Any] in
            ["sampleIndex": key.sampleIndex, "kind": key.kind,
             "notification": key.notification.map { $0 as Any } ?? NSNull(),
             "elementMatchesFocused": key.elementMatchesFocused.map { $0 as Any } ?? NSNull(),
             "elementMatchesWindow": key.elementMatchesWindow.map { $0 as Any } ?? NSNull(),
             "elementMatchesAppRoot": key.elementMatchesAppRoot.map { $0 as Any } ?? NSNull(),
             "elementMatchesRetainedAncestor": key.elementMatchesRetainedAncestor.map { $0 as Any } ?? NSNull(),
             "count": count]
        }
        counts.removeAll(keepingCapacity: true)
        return summary
    }

    func cancel() { underlying.cancel() }
}

@MainActor
private final class AXClarificationPlanner: ComputerUseTextGoalPlanning {
    var goals: [ComputerUseUnresolvedTextGoal] = []
    var observations: [[ComputerUseTextField]] = []
    var beforeProposal: ((ComputerUseUnresolvedTextGoal, [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal?)?

    func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        try await propose(goal: ComputerUseUnresolvedTextGoal(userRequest: prompt), fields: fields)
    }

    func propose(goal: ComputerUseUnresolvedTextGoal, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        goals.append(goal); observations.append(fields)
        if let proposal = try await beforeProposal?(goal, fields) { return proposal }
        guard goal.userTurns.count > 1 else { return .clarification }
        let destination = try XCTUnwrap(fields.first { $0.label == "café" })
        let payload = try XCTUnwrap(ComputerUseTextPayloadCatalog(goal: goal).payloads["p1"])
        return .edits([.init(targetID: destination.snapshot.targetID, mode: .replaceAll, text: payload)],
            unchangedTargetIDs: fields.filter { $0.snapshot.targetID != destination.snapshot.targetID }.map { $0.snapshot.targetID })
    }
}

@MainActor
private final class AXGraphPlanner: ComputerUseTextGoalPlanning {
    var calls = 0
    var beforeProposal: (() -> Void)?
    func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        calls += 1
        let destination = try XCTUnwrap(fields.first { $0.label != "Source" })
        let source = try XCTUnwrap(fields.first { $0.label == "Source" })
        beforeProposal?()
        return .edits([.init(targetID: destination.snapshot.targetID, mode: .replaceAll, text: "Paris")], unchangedTargetIDs: [source.snapshot.targetID])
    }
}

@MainActor
private final class AXTextGraph {
    struct Write { let element: String; let attribute: String }
    struct Call { let element: String; let operation: String }
    private var names = ["application", "window", "other-window", "group", "other-group", "destination", "source", "label", "other-label", "replacement"]
    private var elements: [String: AXUIElement] = [:]
    private var attributes: [String: [String: CFTypeRef]] = [:]
    private var reads: [(String, String)] = []
    var writes: [Write] = []
    var calls: [Call] = []
    var lifecycleFactory: ((ComputerUseAccessibilityTextTarget.Application) -> any ComputerUseAXLifecycleMonitoring)?
    var focused = "destination"
    var applicationIdentity = "fixture-process-launch"
    var applicationAvailable = true
    var afterRead: ((String, String) -> Void)?
    var onCapabilityQuery: (() -> Void)?

    init() {
        // These are local opaque CF handles only. Every operation which could
        // perform AX IPC is supplied by Access below, including timeouts.
        for (index, name) in names.enumerated() { elements[name] = AXUIElementCreateApplication(pid_t(50_000 + index)) }
        set("application", kAXFocusedWindowAttribute, element("window"))
        set("window", kAXRoleAttribute, kAXWindowRole as NSString)
        set("window", kAXTitleAttribute, "Fixture" as NSString)
        set("window", kAXChildrenAttribute, [element("group"), element("other-group")] as CFArray)
        for group in ["group", "other-group"] {
            set(group, kAXRoleAttribute, kAXGroupRole as NSString); set(group, kAXParentAttribute, element("window"))
        }
        for label in ["label", "other-label"] {
            set(label, kAXRoleAttribute, kAXStaticTextRole as NSString); set(label, kAXValueAttribute, "café" as NSString)
        }
        set("source", kAXRoleAttribute, kAXTextFieldRole as NSString)
        set("source", kAXTitleAttribute, "Source" as NSString)
        set("source", kAXValueAttribute, "source text" as NSString)
        set("source", kAXParentAttribute, element("group")); setSelection("source", NSRange(location: 11, length: 0))
        restoreDestination()
    }

    var access: ComputerUseAccessibilityTextTarget.Access {
        .init(frontmost: { [self] in applicationAvailable ? .init(identity: applicationIdentity, root: element("application")) : nil },
              read: { [self] attribute, element in
                  guard let name = name(element) else { return nil }
                  calls.append(.init(element: name, operation: "read"))
                  reads.append((name, attribute))
                  let value: CFTypeRef? = name == "application" && attribute == kAXFocusedUIElementAttribute ? self.element(focused) : attributes[name]?[attribute]
                  afterRead?(name, attribute)
                  return value
              }, canSet: { [self] attribute, element in
                  calls.append(.init(element: name(element) ?? "unknown", operation: "canSet"))
                  onCapabilityQuery?()
                  return ["destination", "source"].contains(name(element) ?? "")
                      && [kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute, kAXValueAttribute].contains(attribute)
              }, write: { [self] attribute, value, element in
                  guard let name = name(element) else { return .invalidUIElement }
                  calls.append(.init(element: name, operation: "write"))
                  writes.append(.init(element: name, attribute: attribute))
                  if attribute == kAXFocusedAttribute { focused = name }
                  else if attribute == kAXSelectedTextRangeAttribute { set(name, attribute, value) }
                  else if attribute == kAXSelectedTextAttribute {
                      guard let old = self.value(name), let rangeValue = attributes[name]?[kAXSelectedTextRangeAttribute],
                            let text = value as? String else { return .failure }
                      var range = CFRange()
                      guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range),
                            let swiftRange = Range(NSRange(location: range.location, length: range.length), in: old) else { return .failure }
                      let updated = old.replacingCharacters(in: swiftRange, with: text)
                      set(name, kAXValueAttribute, updated as NSString); setSelection(name, NSRange(location: range.location + text.utf16.count, length: 0))
                  } else if attribute == kAXValueAttribute {
                      set(name, attribute, value)
                      setSelection(name, NSRange(location: (value as? String ?? "").utf16.count, length: 0))
                  } else { return .attributeUnsupported }
                  return .success
              }, timeout: { [self] element, _ in calls.append(.init(element: name(element) ?? "unknown", operation: "timeout")) },
              makeLifecycleMonitor: lifecycleFactory)
    }
    func element(_ name: String) -> AXUIElement { elements[name]! }
    func addNode(_ name: String) -> AXUIElement {
        names.append(name); elements[name] = AXUIElementCreateApplication(pid_t(50_000 + names.count))
        return elements[name]!
    }
    func setFrame(_ name: String, _ frame: CGRect) {
        var point = frame.origin, size = frame.size
        set(name, kAXPositionAttribute, AXValueCreate(.cgPoint, &point))
        set(name, kAXSizeAttribute, AXValueCreate(.cgSize, &size))
    }
    func set(_ name: String, _ attribute: String, _ value: CFTypeRef?) { attributes[name, default: [:]][attribute] = value }
    func value(_ name: String) -> String? { attributes[name]?[kAXValueAttribute] as? String }
    func setSelection(_ name: String, _ selection: NSRange) {
        var range = CFRange(location: selection.location, length: selection.length)
        set(name, kAXSelectedTextRangeAttribute, AXValueCreate(.cfRange, &range))
    }
    func readCount(_ name: String, _ attribute: String) -> Int { reads.filter { $0.0 == name && $0.1 == attribute }.count }
    func addField(_ name: String, label: String) {
        set(name, kAXRoleAttribute, kAXTextFieldRole as NSString); set(name, kAXTitleAttribute, label as NSString)
        set(name, kAXValueAttribute, "old" as NSString); set(name, "AXEditable", kCFBooleanTrue)
        set(name, kAXParentAttribute, element("group")); setSelection(name, NSRange(location: 3, length: 0))
        set("group", kAXChildrenAttribute, [element("destination"), element("source"), element(name)] as CFArray)
    }
    func moveDestination(to group: String) {
        set("destination", kAXParentAttribute, element(group))
        set("group", kAXChildrenAttribute, (group == "group" ? [element("destination"), element("source")] : [element("source")]) as CFArray)
        set("other-group", kAXChildrenAttribute, (group == "other-group" ? [element("destination")] : []) as CFArray)
    }
    func restoreDestination() {
        attributes["destination"] = [kAXRoleAttribute: kAXTextFieldRole as NSString, kAXTitleAttribute: "café" as NSString,
            kAXValueAttribute: "old" as NSString, "AXIdentifier": "destination" as NSString, kAXTitleUIElementAttribute: element("label")]
        moveDestination(to: "group"); setSelection("destination", NSRange(location: 3, length: 0))
    }
    private func name(_ element: AXUIElement) -> String? { names.first { CFEqual(elements[$0]!, element) } }
}

private final class AXFixtureLifecycleMonitor: ComputerUseAXLifecycleMonitoring {
    private let inbox = ComputerUseAXLifecycleInbox()
    private let callbacks = ComputerUseAXLifecycleCallbacks()
    private let source = NSObject()
    private var registration: ComputerUseAXLifecycleCallbacks.Registration!
    private(set) var cancellations = 0
    init() { registration = callbacks.register(source: source, inbox: inbox) }
    func notify(_ notification: String, element: AXUIElement) { callbacks.deliver(source: source, element: element, notification: notification) }
    func record(_ event: ComputerUseAXLifecycleEvent) { inbox.record(event) }
    func drain() -> [ComputerUseAXLifecycleEvent] { inbox.drain() }
    func cancel() { cancellations += 1; callbacks.remove(registration); inbox.close() }
}
