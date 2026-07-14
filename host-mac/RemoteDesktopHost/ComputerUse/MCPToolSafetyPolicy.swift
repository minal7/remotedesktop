import Foundation

struct MCPToolSafetyAssessment: Equatable, Sendable {
    let risk: MCPToolRisk
    let approval: MCPApprovalDisplay
}

/// Host-owned policy for the pinned MacControlMCP release. Tool annotations,
/// names added by a future server release, and server-provided approval copy
/// are never trusted. A tool must be in one of these reviewed sets to be
/// visible, and every executable call is assessed again with its exact args.
enum MCPToolSafetyPolicy {
    static let acceptanceBlockedToolReasons: [String: String] = [
        "browser_close_tab": "MacControlMCP 0.8.2 activates Safari and targets its ambient front window, so a supposedly isolated call can close a real user tab.",
        "browser_dom_tree": "Requires Safari's developer-only JavaScript from Apple Events setting and fails on the default setup.",
        "browser_get_active_tab": "MacControlMCP 0.8.2 reads Safari's ambient front window rather than a host-owned isolated browser context.",
        "browser_iframes": "Requires Safari's developer-only JavaScript from Apple Events setting and fails on the default setup.",
        "browser_list_tabs": "The result inventories unrelated user tabs and has no host-owned isolated browser context.",
        "browser_navigate": "MacControlMCP 0.8.2 can target Safari's ambient front window, so navigation cannot be confined to host-owned state.",
        "browser_new_tab": "MacControlMCP 0.8.2 runs `activate` and `make new tab` against Safari's ambient front window; the live gate proved it can displace a real user tab.",
        "browser_visible_text": "Requires Safari's developer-only JavaScript from Apple Events setting and fails on the default setup.",
        "calendar_create_event": "The separately signed helper lacks a verified Calendar permission and isolated mutation fixture.",
        "calendar_list_events": "The separately signed helper is denied Calendar access on the default setup.",
        "reminders_create": "No isolated temporary Reminders store and deterministic cleanup fixture is available.",
        "run_shortcut": "macOS provides no local CLI for creating an isolated temporary Shortcut fixture.",
        "scroll_to_element": "The pinned helper scrolls at the ambient pointer instead of the requested PID, and can report an offscreen AX match without scrolling.",
    ]

    static let readOnlyTools: Set<String> = [
        "ax_snapshot_capture",
        "ax_snapshot_diff",
        "ax_tree_augmented",
        "contacts_search",
        "find_element",
        "find_elements",
        "focused_app",
        "get_element_attributes",
        "get_ui_tree",
        "list_apps",
        "list_elements",
        "list_menu_titles",
        "list_shortcuts",
        "list_windows",
        "permissions_status",
        "probe_ax_tree",
        "query_elements",
        "read_value",
        "reminders_list",
        "wait_for_ax_notification",
        "wait_for_element",
        "wait_for_window_state_change",
    ]

    /// These mutations only affect transient focus state and have a
    /// straightforward user-visible undo. They still use the mutation ledger
    /// and are never transport-retried.
    static let reversibleTools: Set<String> = [
        "focus_window",
    ]

    static let approvalRequiredTools: Set<String> = [
        "click",
        "click_menu_path",
        "perform_element_action",
        "press_key",
        "remote_desktop_mail",
        "set_element_attribute",
        "type_text",
    ]

    /// Kept explicit both for reviewability and to prevent a future refactor
    /// from accidentally treating a dangerous known tool like an unknown
    /// read-only helper. Unknown tools are blocked too.
    static let explicitlyBlockedTools: Set<String> = [
        // Arbitrary code, shell-equivalent dispatch, or indirect launch.
        "browser_eval_js",
        "command",
        "execute_command",
        "foundation_models_generate",
        "invoke_app_intent",
        "list_app_intents",
        "open_url_scheme",
        "osascript",
        "run_command",
        "shell",

        // MacControlMCP 0.8.2's implementation does not address `send` to
        // the outgoing message and does not create a visible draft. Never
        // expose that broken mutation; the signed host owns a narrower MCP
        // tool with a fixed argv-bound AppleScript implementation instead.
        "mail_send",

        // v0.8.2's browser controller activates Safari and addresses its
        // ambient front window. A minimized host fixture therefore causes the
        // helper to act on an unrelated user window. Keep every browser-tab
        // operation out of production; GUI/browser tasks fall through to the
        // intervention-aware OS-Atlas visual executor instead.
        "browser_close_tab",
        "browser_get_active_tab",
        "browser_list_tabs",
        "browser_navigate",
        "browser_new_tab",

        // These advertised v0.8.2 tools did not pass the signed-helper E2E
        // gate on a default Mac. The DOM wrappers fail unless the user enables
        // Safari's developer-only "Allow JavaScript from Apple Events"
        // switch. Calendar is denied to the separately signed helper even
        // when the host has its normal permissions. Keep them hidden until a
        // capability-aware setup and a clean end-to-end fixture exist.
        "browser_dom_tree",
        "browser_iframes",
        "browser_visible_text",
        "calendar_create_event",
        "calendar_list_events",

        // These mutations have no safe, isolated fixture in the current
        // release. Exposing them without a success-path E2E check risks
        // changing the user's real Reminders/Shortcuts data during testing.
        "reminders_create",
        "run_shortcut",
        "scroll_to_element",

        // Cross-user communications outside the reviewed Mail contract.
        "imessage_list_recent",
        "imessage_send",

        // Clipboard contents are an ambient secret and clipboard mutation is
        // not needed because the reviewed type_text tool owns text entry.
        "clipboard_clear",
        "clipboard_read",
        "clipboard_write",

        // Filesystem/path operations.
        "file_dialog_cancel",
        "file_dialog_confirm",
        "file_dialog_select_item",
        "file_dialog_set_path",
        "quick_look",
        "reveal_in_finder",
        "spotlight_open_result",
        "spotlight_search",
        "trash_file",

        // Power/session operations.
        "lock_screen",
        "system_logout",
        "system_restart",
        "system_shutdown",
        "system_sleep",

        // Hardware, network, capture, and system configuration.
        "audio_record",
        "battery_status",
        "bluetooth_devices",
        "bluetooth_set",
        "capture_display",
        "capture_screen",
        "capture_screen_v2",
        "capture_window",
        "disk_usage",
        "list_audio_devices",
        "mic_mute",
        "network_info",
        "night_shift_set",
        "open_airplay_preferences",
        "record_screen",
        "set_audio_input",
        "set_audio_output",
        "set_brightness",
        "set_focus_mode",
        "set_volume",
        "speech_to_text",
        "system_load",
        "text_to_speech",
        "wifi_join",
        "wifi_scan",
        "wifi_set",
    ]

    static var allowedTools: Set<String> {
        readOnlyTools.union(reversibleTools).union(approvalRequiredTools)
    }

    static func risk(for toolName: String) -> MCPToolRisk {
        if readOnlyTools.contains(toolName) { return .readOnly }
        if reversibleTools.contains(toolName) { return .reversible }
        if approvalRequiredTools.contains(toolName) { return .approvalRequired }
        return .blocked
    }

    static func isAllowed(_ toolName: String) -> Bool {
        risk(for: toolName) != .blocked
    }

    static func assess(
        toolName: String,
        arguments: [String: MCPJSONValue] = [:]
    ) -> MCPToolSafetyAssessment {
        let risk = risk(for: toolName)
        return MCPToolSafetyAssessment(
            risk: risk,
            approval: approvalDisplay(
                toolName: toolName,
                arguments: arguments,
                risk: risk))
    }

    /// Restrictions that are narrower than the server's published JSON
    /// schema. In particular, a navigation URL must not become an indirect
    /// JavaScript, file, or custom-scheme execution path.
    static func validateArguments(
        toolName: String,
        arguments: [String: MCPJSONValue]
    ) throws {
        if toolName == "run_shortcut",
           let name = arguments.string("name"),
           name.utf8.count > 256 {
            throw MCPClientError.invalidArguments(
                "The Shortcut name exceeds the host limit.")
        }

        if toolName == RemoteDesktopMailMCP.toolName {
            _ = try RemoteDesktopMailRequest(arguments: arguments)
        }

    }

    private static func approvalDisplay(
        toolName: String,
        arguments: [String: MCPJSONValue],
        risk: MCPToolRisk
    ) -> MCPApprovalDisplay {
        switch toolName {
        case "type_text":
            let count = arguments.string("text")?.count ?? 0
            return MCPApprovalDisplay(
                summary: "Type text on this Mac?",
                details: "Type \(count) characters into the currently focused field. The text is hidden here for privacy.",
                confirmLabel: "Type text")

        case RemoteDesktopMailMCP.toolName:
            let recipient = safe(arguments.string("to"), fallback: "the selected recipients")
            let subject = safe(arguments.string("subject"), fallback: "(no subject)")
            let sendsNow = arguments.bool("send_now") ?? false
            return MCPApprovalDisplay(
                summary: sendsNow ? "Send this email?" : "Create this email draft?",
                details: "From: Your default account in Mail\nTo: \(recipient)\nSubject: \(subject)\nThe message body is hidden here for privacy. On first use, macOS may ask on your Mac; choose Allow so Remote Desktop Host can use Mail.",
                confirmLabel: sendsNow ? "Send email" : "Create draft")

        case "calendar_create_event":
            return MCPApprovalDisplay(
                summary: "Create this calendar event?",
                details: "\(safe(arguments.string("summary"), fallback: "Untitled event"))\n\(safe(arguments.string("start_iso"), fallback: "Unknown start")) to \(safe(arguments.string("end_iso"), fallback: "unknown end"))",
                confirmLabel: "Create event")

        case "reminders_create":
            var details = safe(arguments.string("title"), fallback: "Untitled reminder")
            if let due = arguments.string("due_iso") {
                details += "\nDue: \(safe(due, fallback: "unspecified"))"
            }
            return MCPApprovalDisplay(
                summary: "Create this reminder?",
                details: details,
                confirmLabel: "Create reminder")

        case "run_shortcut":
            return MCPApprovalDisplay(
                summary: "Run this Shortcut?",
                details: "Shortcut: \(safe(arguments.string("name"), fallback: "Unknown Shortcut"))\nShortcut input is hidden here for privacy.",
                confirmLabel: "Run Shortcut")

        case "click":
            let target: String
            if let title = arguments.string("title") {
                target = "Element titled \(safe(title, fallback: "untitled"))"
            } else if let x = arguments.numberDescription("x"),
                      let y = arguments.numberDescription("y") {
                target = "Screen coordinate (\(x), \(y))"
            } else {
                target = "The selected accessibility element"
            }
            return MCPApprovalDisplay(
                summary: "Click on this Mac?",
                details: target,
                confirmLabel: "Click")

        case "press_key":
            let key = safe(arguments.string("key"), fallback: "unknown key")
            return MCPApprovalDisplay(
                summary: "Press a key on this Mac?",
                details: "Key: \(key)",
                confirmLabel: "Press key")

        case "click_menu_path":
            let path = arguments.stringArray("path").map {
                $0.map { safe($0, fallback: "item") }.joined(separator: " > ")
            } ?? "Selected menu item"
            return MCPApprovalDisplay(
                summary: "Choose this menu command?",
                details: path,
                confirmLabel: "Choose command")

        case "set_element_attribute", "perform_element_action", "scroll_to_element":
            return MCPApprovalDisplay(
                summary: "Control this app on your Mac?",
                details: "Perform the reviewed accessibility action \(toolName). Argument values are hidden here for privacy.",
                confirmLabel: "Allow action")

        default:
            switch risk {
            case .readOnly:
                return MCPApprovalDisplay(
                    summary: "Read Mac app information",
                    details: "Use the reviewed \(toolName) observation.",
                    confirmLabel: "Continue")
            case .reversible:
                return MCPApprovalDisplay(
                    summary: "Change the current Mac view",
                    details: "Use the reviewed, reversible \(toolName) action.",
                    confirmLabel: "Continue")
            case .approvalRequired:
                return MCPApprovalDisplay(
                    summary: "Control this app on your Mac?",
                    details: "Perform the reviewed \(toolName) action. Argument values are hidden here for privacy.",
                    confirmLabel: "Allow action")
            case .blocked:
                return MCPApprovalDisplay(
                    summary: "This Mac action is blocked",
                    details: "The host does not allow the \(toolName) tool.",
                    confirmLabel: "Blocked")
            }
        }
    }

    private static func safe(_ value: String?, fallback: String) -> String {
        guard let value else { return fallback }
        let collapsed = value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return fallback }
        return String(collapsed.prefix(180))
    }
}

private extension Dictionary where Key == String, Value == MCPJSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value) = self[key] else { return nil }
        return value
    }

    func bool(_ key: String) -> Bool? {
        guard case .bool(let value) = self[key] else { return nil }
        return value
    }

    func stringArray(_ key: String) -> [String]? {
        guard case .array(let values) = self[key] else { return nil }
        return values.compactMap {
            guard case .string(let value) = $0 else { return nil }
            return value
        }
    }

    func numberDescription(_ key: String) -> String? {
        switch self[key] {
        case .integer(let value): return String(value)
        case .double(let value): return String(value)
        default: return nil
        }
    }
}
