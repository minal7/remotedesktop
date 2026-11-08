import CoreGraphics
import Foundation

/// A deterministic check on every action, independent of the model. Screens can
/// carry prompt injections and small models make mistakes, so this never asks the
/// model whether something is safe.
public struct SafetyPolicy: Sendable {
    public enum Decision: Sendable, Equatable {
        case allow
        case approve(reason: String, high: Bool)
        case handoff(String)
        case refuse(String)
    }

    public init() {}

    private static let consequential: [(word: String, reason: String)] = [
        ("send", "send something"), ("reply", "send a reply"), ("forward", "forward a message"),
        ("upload", "send a file to a website"), ("post", "post publicly"), ("publish", "publish something"), ("tweet", "post publicly"), ("share", "share something"),
        ("pay", "make a payment"), ("buy", "buy something"), ("purchase", "buy something"), ("order", "place an order"),
        ("checkout", "check out"), ("subscribe", "start a subscription"), ("donate", "donate money"), ("transfer", "move money"),
        ("withdraw", "move money"), ("deposit", "move money"), ("delete", "delete something"), ("remove", "remove something"),
        ("erase", "erase something"), ("trash", "move something to the trash"), ("empty", "permanently remove something"),
        ("discard", "discard work"), ("overwrite", "overwrite something"), ("replace", "replace an existing file"),
        ("uninstall", "uninstall software"), ("install", "install software"),
        ("sign", "sign something"), ("agree", "accept terms"), ("accept", "accept something"), ("authorize", "grant access"),
        ("grant", "grant access"), ("allow", "grant permission"), ("submit", "submit a form"), ("confirm", "confirm something"),
        ("book", "make a booking"), ("reserve", "make a reservation"), ("cancel subscription", "cancel a subscription"),
        ("log out", "sign out"), ("sign out", "sign out"), ("reset", "reset something"), ("restart", "restart the computer"),
        ("shut down", "shut down the computer"),
    ]

    /// Words that look like a trigger above but are everyday navigation.
    private static let benign: [String] = [
        "search", "send feedback", "sign in", "sign up", "signin", "signup", "post office", "postal", "sort order", "order by",
        "reorder", "share sheet", "format painter", "text format", "paragraph format", "booking.com", "bookmark", "bookmarks",
        "book a demo", "notebook", "facebook", "replace all", "find and replace", "find & replace", "accept cookies",
        "empty state", "allow cookies", "reset zoom", "reset filters", "delete word", "resend",
    ]

    private static let onlySelects: Set<String> = ["tab", "radio", "field", "search", "combo", "slider", "stepper"]

    private static let forbiddenApps: Set<String> = ["keychain access", "passwords"]
    private static let sensitiveApps: [String: String] = [
        "terminal": "run commands", "iterm": "run commands", "iterm2": "run commands", "warp": "run commands",
        "system settings": "change system settings", "system preferences": "change system settings",
        "script editor": "run scripts", "automator": "run automations", "disk utility": "change disks",
    ]
    private static let messagingApps: Set<String> = [
        "mail", "messages", "slack", "discord", "teams", "microsoft teams", "whatsapp", "telegram", "signal", "outlook",
        "microsoft outlook", "wechat", "zoom",
    ]
    private static let commandAppBundles: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.apple.ScriptEditor2",
    ]

    /// macOS asking the person for permission or a password. Only they should answer those.
    private static let systemDialogs: Set<String> = ["com.apple.UserNotificationCenter", "com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent", "com.apple.coreservices.uiagent"]

    /// These models aim a few pixels off, and a click just outside a small button does nothing.
    /// Returns the middle of a control the point narrowly missed. A point already on a control,
    /// or near several at about the same distance, stays where it is. Safety judges everything
    /// around the point first, so this can't reach a button that wasn't checked.
    public static func nearestControl(to point: CGPoint, in scene: Scene, within reach: CGFloat = 12) -> CGPoint? {
        let window = scene.windowFrame.width * scene.windowFrame.height
        let controls = scene.elements.filter {
            $0.isInteractive && $0.frame.width > 0 && $0.frame.height > 0 && (window == 0 || $0.frame.width * $0.frame.height < window / 4)
        }
        if controls.contains(where: { $0.frame.contains(point) }) { return nil }
        func distance(_ frame: CGRect) -> CGFloat {
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX), dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            return (dx * dx + dy * dy).squareRoot()
        }
        let near = controls.map { (control: $0, distance: distance($0.frame)) }.filter { $0.distance <= reach }.sorted { $0.distance < $1.distance }
        guard let best = near.first else { return nil }
        if near.count > 1, near[1].distance - best.distance < 3 { return nil }
        return best.control.center
    }

    public static func isSystemDialog(_ scene: Scene) -> Bool { systemDialogs.contains(scene.bundleID) }

    public func evaluate(_ call: ToolCall, scene: Scene) -> Decision {
        switch call {
        case let .click(id, _, _):
            guard let element = scene.element(id: id) else { return .allow }
            return judge(label: element.label, verb: "click", context: scene)

        case let .clickAt(x, y):
            let point = Self.point(x: x, y: y, in: scene)
            // A known control under the pointer is what gets clicked, whatever sits beside it.
            let controls = scene.elements.filter { $0.isInteractive && !$0.label.isEmpty && $0.frame.contains(point) }
            if let hit = controls.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                // Choosing a tab or putting the cursor in a field commits to nothing, even
                // when a browser tab carries a page title like "Order Stoneware Mug".
                if Self.onlySelects.contains(hit.role) { return .allow }
                return judge(label: hit.label, verb: "click", context: scene)
            }
            // Nothing is listed there, but whatever is drawn nearby may be a live button.
            let window = scene.windowFrame.width * scene.windowFrame.height
            let nearby = scene.elements.filter {
                $0.frame.insetBy(dx: -24, dy: -16).contains(point) && (window == 0 || $0.frame.width * $0.frame.height < window / 2)
            }
            for element in nearby {
                let decision = judge(label: element.label, verb: "click", context: scene)
                if decision != .allow { return decision }
            }
            return .allow

        case let .type(id, text, _, submit):
            let target = id.flatMap(scene.element(id:)) ?? scene.focused
            if scene.url != nil, Self.runsInBrowser(text) {
                return .refuse("Typing a script address into a browser would run code on the page.")
            }
            if target?.secure == true {
                return .handoff("A password is needed in \(scene.appName). Enter it yourself, then tap Resume.")
            }
            if Self.commandAppBundles.contains(scene.bundleID) {
                return .approve(reason: "Type this into \(scene.appName), which can run commands: \(text.prefix(120))", high: true)
            }
            if submit, Self.messagingApps.contains(scene.appName.lowercased()) {
                return .approve(reason: "Press Return in \(scene.appName), which may send this: \(text.prefix(120))", high: true)
            }
            if Self.looksLikeCardNumber(text) {
                return .approve(reason: "Type what looks like a card number into \(scene.appName).", high: true)
            }
            return .allow

        case let .key(chord):
            let normalized = chord.lowercased().replacingOccurrences(of: " ", with: "")
            let isReturn = normalized.hasSuffix("return") || normalized.hasSuffix("enter")
            if isReturn, Self.messagingApps.contains(scene.appName.lowercased()) {
                return .approve(reason: "Press \(chord) in \(scene.appName), which may send a message.", high: true)
            }
            if isReturn, normalized.contains("cmd") || normalized.contains("command") {
                return .approve(reason: "Press \(chord) in \(scene.appName), which usually sends or submits.", high: true)
            }
            if isReturn, Self.commandAppBundles.contains(scene.bundleID) {
                return .approve(reason: "Press \(chord) in \(scene.appName), which runs the current command.", high: true)
            }
            if normalized.contains("shift"), normalized.contains("cmd"), normalized.hasSuffix("delete") {
                return .approve(reason: "Empty the Trash or permanently delete with \(chord).", high: true)
            }
            if normalized.contains("cmd"), normalized.hasSuffix("delete") {
                return .approve(reason: "Delete the selected item with \(chord).", high: true)
            }
            if isReturn, let button = scene.elements.first(where: { $0.inModal && $0.role == "button" && $0.focused }) {
                return judge(label: button.label, verb: "press Return on", context: scene)
            }
            return .allow

        case let .menu(path):
            let leaf = path.components(separatedBy: ">").last?.trimmingCharacters(in: .whitespaces) ?? path
            return judge(label: leaf, verb: "choose the menu item", context: scene)

        case let .openApp(name):
            let key = name.lowercased().replacingOccurrences(of: ".app", with: "")
            if Self.forbiddenApps.contains(key) {
                return .handoff("\(name) holds saved passwords. I don't open it; use it yourself if you need to.")
            }
            if let purpose = Self.sensitiveApps[key] {
                return .approve(reason: "Open \(name), which can \(purpose).", high: true)
            }
            return .allow

        case let .openURL(url):
            let lower = url.lowercased()
            if lower.hasPrefix("file:") || lower.hasPrefix("javascript:") || lower.hasPrefix("data:") {
                return .refuse("Only web addresses can be opened this way.")
            }
            return .allow

        case let .drag(fromID, toID):
            for id in [fromID, toID] {
                if let element = scene.element(id: id) {
                    let decision = judge(label: element.label, verb: "drag", context: scene)
                    if decision != .allow { return decision }
                }
            }
            return .allow

        case let .pointAt(x, y, _, _):
            return evaluate(.clickAt(x: x, y: y), scene: scene)

        case let .dragAt(fromX, fromY, toX, toY):
            let from = evaluate(.clickAt(x: fromX, y: fromY), scene: scene)
            return from != .allow ? from : evaluate(.clickAt(x: toX, y: toY), scene: scene)

        case let .typeAtFocus(text):
            // A trailing newline is Return, with the same consequences as pressing it.
            return evaluate(.type(id: nil, text: text, clear: false, submit: text.hasSuffix("\n")), scene: scene)

        case .moveTo, .scrollBy, .scroll, .find, .look, .zoom, .read, .note, .wait, .askUser, .done, .fail:
            return .allow
        }
    }

    private func judge(label: String, verb: String, context scene: Scene) -> Decision {
        let lower = label.lowercased()
        guard !lower.isEmpty else { return .allow }
        if Self.benign.contains(where: { lower.contains($0) }) { return .allow }
        for entry in Self.consequential where Self.containsWord(entry.word, in: lower) {
            // Replacing a file is always asked in a dialog. Anywhere else it means find and replace.
            if entry.word == "replace", !scene.hasModal { continue }
            let location = scene.url.flatMap { URL(string: $0)?.host } ?? scene.appName
            return .approve(reason: "This would \(entry.reason): \(verb) \"\(label.prefix(50))\" in \(location).", high: true)
        }
        return .allow
    }

    /// The same addresses `openURL` refuses, typed by hand into an address bar.
    static func runsInBrowser(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("file:")
    }

    static func containsWord(_ word: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: word, range: searchRange) {
            let beforeOK = found.lowerBound == text.startIndex || !text[text.index(before: found.lowerBound)].isLetter
            // Also allow verb endings: "sending", "deleted", "purchases".
            let tail = text[found.upperBound...].prefix { $0.isLetter }
            if beforeOK, ["", "s", "es", "ed", "d", "ing", "now"].contains(String(tail)) { return true }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }

    static func looksLikeCardNumber(_ text: String) -> Bool {
        let digits = text.filter(\.isNumber).map { Int(String($0)) ?? 0 }
        guard (13...19).contains(digits.count), text.filter({ !$0.isNumber && $0 != " " && $0 != "-" }).isEmpty else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else { sum += digit }
        }
        return sum % 10 == 0
    }

    /// 0–1000 screenshot coordinates to global screen points.
    public static func point(x: Double, y: Double, in scene: Scene) -> CGPoint {
        let rect = scene.screenshot?.rect ?? scene.windowFrame
        return CGPoint(x: rect.minX + rect.width * min(1000, max(0, x)) / 1000,
                       y: rect.minY + rect.height * min(1000, max(0, y)) / 1000)
    }
}
