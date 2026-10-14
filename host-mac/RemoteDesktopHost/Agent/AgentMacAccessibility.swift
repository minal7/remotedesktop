import AppKit
import ApplicationServices
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@MainActor
final class AgentMacAccessibility {
    struct Window {
        let application: NSRunningApplication
        let element: AXUIElement
        let bounds: CGRect
        let number: CGWindowID
        let title: String
        var identity: String {
            "\(application.processIdentifier):\(application.launchDate?.timeIntervalSince1970 ?? 0):\(number)"
        }
    }

    struct Tree {
        let elements: [AgentElement]
        let focus: AgentFocus?
        let secureRects: [CGRect]
        let authorityDigest: String
        let consistencyDigest: String
    }

    struct EditableAuthorityRecord: Codable, Equatable {
        let id: Int
        let role: String
        let subrole: String
        let identifier: String
        let name: String
        let value: String
        let selected: Bool?
        let selection: AgentSelection?
    }

    private struct LayoutRecord: Codable {
        let id: Int?
        let role: String?
        let subrole: String?
        let identifier: String?
        let name: String?
        let value: String?
        let state: [String]?
        let rect: [Double]
        let secure: Bool
    }

    enum AuthorityDigest {
        static func encode(_ records: [EditableAuthorityRecord]) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(records.sorted { $0.id < $1.id })
            return hex(SHA256.hash(data: data))
        }

        private static func hex(_ digest: SHA256.Digest) -> String {
            digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    private var bindings: [(element: AXUIElement, id: Int)] = []
    private var windowIdentity: String?
    private(set) var currentWindow: Window?
    private(set) var captureSize = CGSize.zero

    static func matchingWindowID(ownerPID: Int32, bounds: CGRect, focusedTitle: String?,
                                 entries: [[String: Any]]? = nil) -> UInt32? {
        let windows = entries ?? (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
        let candidates = windows.filter {
            guard $0[kCGWindowOwnerPID as String] as? Int32 == ownerPID,
                  let raw = $0[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return false }
            return ElementMarks.focusedWindowMatches(bounds, selectedBounds: frame)
        }
        let title = focusedTitle.flatMap { $0.isEmpty ? nil : $0 }
        let selected = title.flatMap { title in candidates.first { $0[kCGWindowName as String] as? String == title } }
            ?? (title == nil ? candidates.first : nil)
        return selected?[kCGWindowNumber as String] as? UInt32
    }

    func window() throws -> Window {
        guard AXIsProcessTrusted(), let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != nil else { throw AgentEnvironmentError.unavailable("Accessibility permission or a focused app is unavailable.") }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        guard let focused = axElement(read(root, kAXFocusedWindowAttribute)),
              let bounds = rect(focused), !bounds.isEmpty,
              let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw AgentEnvironmentError.unavailable("The focused window could not be identified.")
        }
        let focusedTitle = read(focused, kAXTitleAttribute) as? String
        guard let number = Self.matchingWindowID(ownerPID: application.processIdentifier, bounds: bounds,
            focusedTitle: focusedTitle, entries: entries) else {
            throw AgentEnvironmentError.scopeChanged
        }
        guard ComputerUseVisibleWindowStack(windowInfo: entries)
            .assessFocusedWindow(ownerProcessIdentifier: application.processIdentifier, bounds: bounds) == .clear else {
            throw AgentEnvironmentError.targetCovered
        }
        let result = Window(application: application, element: focused, bounds: bounds, number: number,
                            title: focusedTitle ?? "")
        if windowIdentity != result.identity { bindings.removeAll(); windowIdentity = result.identity }
        currentWindow = result
        return result
    }

    func tree(_ window: Window, size: CGSize, byteBudget: Int = 48 * 1024) throws -> Tree {
        let app = AXUIElementCreateApplication(window.application.processIdentifier)
        let focused = axElement(read(app, kAXFocusedUIElementAttribute))
        var queue = [window.element], cursor = 0, seen: [AXUIElement] = []
        var elements: [AgentElement] = [], secureRects: [CGRect] = [], focus: AgentFocus?
        var consistencyFocus: AgentFocus?
        var authorityRecords: [EditableAuthorityRecord] = []
        var layoutRecords: [LayoutRecord] = []
        var usedBytes = 0
        let deadline = Date().addingTimeInterval(2)
        while cursor < queue.count {
            try Task.checkCancellation()
            guard Date() < deadline else { throw AgentEnvironmentError.unavailable("The Accessibility tree exceeded its read deadline.") }
            let element = queue[cursor]; cursor += 1
            guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
            seen.append(element)
            AXUIElementSetMessagingTimeout(element, 0.15)
            queue.append(contentsOf: axElements(read(element, kAXChildrenAttribute)))
            let role = read(element, kAXRoleAttribute) as? String ?? "unknown"
            let subrole = read(element, kAXSubroleAttribute) as? String ?? ""
            let name = (read(element, kAXTitleAttribute) as? String)
                ?? (read(element, kAXDescriptionAttribute) as? String) ?? ""
            let secure = AgentCredentialRule.isSensitive(role: role, name: name, state: [subrole])
            let id = identity(element)
            let editable = isEditable(element, role: role)
            var fullValue: String?
            if editable && !secure {
                let rawValue = read(element, kAXValueAttribute)
                let represented = try canonicalEditableValue(rawValue)
                fullValue = represented.textValue
                guard name.utf8.count <= 4_096 else {
                    throw AgentEnvironmentError.unavailable("Editable Accessibility state could not be read safely.")
                }
                let selected = try selectedState(element)
                let selection = try selectedRange(element, valueLength: fullValue?.utf16.count)
                authorityRecords.append(.init(id: id, role: role, subrole: subrole,
                    identifier: string(element, "AXIdentifier") ?? "", name: name,
                    value: represented.value, selected: selected, selection: selection))
            }
            let screenRect = rect(element)
            guard let screenRect, !screenRect.isEmpty else {
                if secure { throw AgentEnvironmentError.unavailable("A secure control could not be masked safely.") }
                continue
            }
            let box = pixelRect(screenRect, window: window.bounds, size: size)
            if secure { secureRects.append(box) }
            // Inspect security before AXValue: secure values are never fetched.
            let value = secure ? nil : (fullValue ?? (read(element, kAXValueAttribute) as? String))
            var state = [read(element, kAXEnabledAttribute) as? Bool == false ? "disabled" : "enabled"]
            if secure { state.append("secure") }
            if read(element, kAXModalAttribute) as? Bool == true { state.append("modal") }
            let record = AgentElement(id: id, role: role, name: String(name.prefix(1024)),
                value: value.map { String($0.prefix(4096)) }, state: state,
                bbox: .init(x: box.minX, y: box.minY, width: box.width, height: box.height),
                inView: window.bounds.intersects(screenRect))
            if secure {
                layoutRecords.append(.init(id: nil, role: nil, subrole: nil, identifier: nil,
                    name: nil, value: nil, state: nil, rect: rectComponents(screenRect), secure: true))
            } else {
                layoutRecords.append(.init(id: id, role: role, subrole: subrole,
                    identifier: string(element, "AXIdentifier") ?? "", name: String(name.prefix(1024)),
                    value: value.map { String($0.prefix(4096)) }, state: state,
                    rect: rectComponents(screenRect), secure: false))
            }
            let isFocused = focused.map { CFEqual($0, element) } == true
            let cost = (try? JSONEncoder().encode(record).count) ?? byteBudget
            if usedBytes + cost <= byteBudget || isFocused { elements.append(record); usedBytes += cost }
            if isFocused {
                let selection = secure ? AgentSelection(start: 0, end: 0)
                    : (try selectedRange(element, valueLength: (value ?? "").utf16.count)) ?? AgentSelection(start: 0, end: 0)
                focus = .init(id: id, role: role, name: record.name, valuePrefix: secure ? "" : String((value ?? "").prefix(1024)), selection: selection)
                if !secure { consistencyFocus = focus }
            }
        }
        let authorityDigest = try AuthorityDigest.encode(authorityRecords)
        let consistencyDigest = try digest(layoutRecords: layoutRecords, authorityDigest: authorityDigest, focus: consistencyFocus)
        return .init(elements: elements, focus: focus, secureRects: secureRects,
                     authorityDigest: authorityDigest, consistencyDigest: consistencyDigest)
    }

    func capture(_ window: Window) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == window.number }),
              target.owningApplication?.processID == window.application.processIdentifier,
              target.frame == window.bounds else { throw AgentEnvironmentError.scopeChanged }
        let scale = min(1, 1280 / max(window.bounds.width, window.bounds.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((window.bounds.width * scale).rounded()))
        configuration.height = max(1, Int((window.bounds.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: .init(desktopIndependentWindow: target), configuration: configuration)
        captureSize = .init(width: image.width, height: image.height)
        return image
    }

    func png(_ image: CGImage, masking rects: [CGRect]) throws -> Data {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AgentEnvironmentError.unavailable("Could not encode the task screenshot.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for rect in rects { context.fill(CGRect(x: rect.minX, y: CGFloat(image.height) - rect.maxY, width: rect.width, height: rect.height)) }
        let bytes = NSMutableData()
        guard let redacted = context.makeImage(), let encoder = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw AgentEnvironmentError.unavailable("Could not encode the task screenshot.")
        }
        CGImageDestinationAddImage(encoder, redacted, nil)
        guard CGImageDestinationFinalize(encoder) else { throw AgentEnvironmentError.unavailable("Could not encode the task screenshot.") }
        return bytes as Data
    }

    func element(_ id: Int) throws -> AXUIElement {
        guard let entry = bindings.first(where: { $0.id == id }) else { throw AgentEnvironmentError.targetGone }
        return entry.element
    }

    func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func rect(_ element: AXUIElement) -> CGRect? {
        guard let position = read(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = read(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        let positionValue = unsafeBitCast(position, to: AXValue.self)
        let sizeValue = unsafeBitCast(size, to: AXValue.self)
        guard AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    func fullEditableString(_ element: AXUIElement) throws -> String {
        guard let value = read(element, kAXValueAttribute) as? String,
              value.utf8.count <= 1_048_576 else {
            throw AgentEnvironmentError.unavailable("Editable text could not be read completely.")
        }
        return value
    }

    func isSensitive(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute) ?? "unknown"
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        let name = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute) ?? ""
        return AgentCredentialRule.isSensitive(role: role, name: name, state: [subrole])
    }

    func editableValueIsSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    func isTextEditable(_ element: AXUIElement) -> Bool {
        isEditable(element, role: string(element, kAXRoleAttribute) ?? "unknown")
    }

    func focusedTextElementIs(_ id: Int, in window: Window) -> Bool {
        guard (try? self.window().identity) == window.identity,
              focusedElementID(in: window) == id,
              let bound = try? element(id),
              isTextEditable(bound), !isSensitive(bound) else { return false }
        return true
    }

    func focusedElementID(in window: Window) -> Int? {
        guard currentWindow?.identity == window.identity,
              let focused = axElement(read(AXUIElementCreateApplication(window.application.processIdentifier), kAXFocusedUIElementAttribute)),
              let binding = bindings.first(where: { CFEqual($0.element, focused) }) else { return nil }
        return binding.id
    }

    func selectedTextRangeIsSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    func setSelection(_ selection: AgentSelection, on element: AXUIElement) throws {
        try selection.validate()
        var range = CFRange(location: selection.start, length: selection.end - selection.start)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
            throw AgentEnvironmentError.targetChanged
        }
    }

    func selection(_ element: AXUIElement, valueLength: Int?) throws -> AgentSelection? {
        try selectedRange(element, valueLength: valueLength)
    }

    private func isEditable(_ element: AXUIElement, role: String) -> Bool {
        if editableValueIsSettable(element) { return true }
        return ["AXTextField", "AXTextArea", "AXTextView", "AXSearchField", "AXComboBox"].contains(role)
    }

    private func canonicalEditableValue(_ raw: CFTypeRef?) throws -> (value: String, textValue: String?) {
        guard let raw else { throw AgentEnvironmentError.unavailable("Editable Accessibility value is unavailable.") }
        if let text = raw as? String, text.utf8.count <= 1_048_576 { return ("string:" + text, text) }
        if CFGetTypeID(raw) == CFBooleanGetTypeID(), let number = raw as? NSNumber {
            return ("boolean:" + (number.boolValue ? "true" : "false"), nil)
        }
        if let number = raw as? NSNumber {
            return ("number:" + number.stringValue, nil)
        }
        throw AgentEnvironmentError.unavailable("Editable Accessibility value has an unsupported representation.")
    }

    private func selectedState(_ element: AXUIElement) throws -> Bool? {
        guard let value = read(element, "AXSelected") else { return nil }
        guard CFGetTypeID(value) == CFBooleanGetTypeID(), let selected = value as? NSNumber else {
            throw AgentEnvironmentError.unavailable("Editable selection state is malformed.")
        }
        return selected.boolValue
    }

    private func selectedRange(_ element: AXUIElement, valueLength: Int?) throws -> AgentSelection? {
        guard let value = read(element, kAXSelectedTextRangeAttribute) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            throw AgentEnvironmentError.unavailable("Editable selection range is malformed.")
        }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            throw AgentEnvironmentError.unavailable("Editable selection range is unavailable.")
        }
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        guard !overflow, valueLength.map({ end <= $0 }) ?? true else {
            throw AgentEnvironmentError.unavailable("Editable selection range exceeds its value.")
        }
        return AgentSelection(start: range.location, end: end)
    }

    private func digest(layoutRecords: [LayoutRecord], authorityDigest: String, focus: AgentFocus?) throws -> String {
        struct Payload: Encodable { let authorityDigest: String; let layout: [LayoutRecord]; let focus: AgentFocus? }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = Payload(authorityDigest: authorityDigest, layout: layoutRecords, focus: focus)
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        read(element, attribute) as? String
    }

    private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func axElements(_ value: CFTypeRef?) -> [AXUIElement] {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = unsafeBitCast(value, to: CFArray.self)
        var result: [AXUIElement] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let item = CFArrayGetValueAtIndex(array, index) else { continue }
            let object = Unmanaged<AnyObject>.fromOpaque(item).takeUnretainedValue()
            let reference = object as CFTypeRef
            guard CFGetTypeID(reference) == AXUIElementGetTypeID() else { continue }
            result.append(unsafeBitCast(reference, to: AXUIElement.self))
        }
        return result
    }

    private func rectComponents(_ rect: CGRect) -> [Double] {
        [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
    }

    private func identity(_ element: AXUIElement) -> Int {
        if let old = bindings.first(where: { CFEqual($0.element, element) }) { return old.id }
        let id = bindings.count; bindings.append((element, id)); return id
    }

    private func pixelRect(_ rect: CGRect, window: CGRect, size: CGSize) -> CGRect {
        CGRect(x: (rect.minX - window.minX) * size.width / window.width,
               y: (rect.minY - window.minY) * size.height / window.height,
               width: rect.width * size.width / window.width, height: rect.height * size.height / window.height)
    }
}
