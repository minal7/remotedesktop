import Foundation

struct MCPComputerUseApprovalPresentation: Equatable, Sendable {
    let message: String
    let details: [ComputerUseApprovalRequest.Detail]
    let confirmLabel: String
}

extension MCPPreparedApproval {
    /// Converts the exact canonical call held by the host into plain-language
    /// mobile approval copy. Values come from the fingerprinted call, not from
    /// model-written prose or server annotations.
    var computerUsePresentation: MCPComputerUseApprovalPresentation {
        let arguments = call.arguments
        switch call.toolName {
        case RemoteDesktopMailMCP.toolName:
            let sendsNow = arguments["send_now"]?.boolValue ?? false
            return MCPComputerUseApprovalPresentation(
                message: sendsNow
                    ? "Send this email through Mail on your Mac?"
                    : "Create this email draft in Mail on your Mac?",
                details: Self.details([
                    ("From", "Your default account in Mail"),
                    ("To", arguments["to"]?.displayValue),
                    ("CC", arguments["cc"]?.displayValue),
                    ("BCC", arguments["bcc"]?.displayValue),
                    ("Subject", arguments["subject"]?.displayValue),
                    ("Message", arguments["body"]?.displayValue),
                    ("Attachment 1", arguments["attachment_paths"]?.attachmentPathsValue(at: 0)),
                    ("Attachment 2", arguments["attachment_paths"]?.attachmentPathsValue(at: 1)),
                    ("Attachment 3", arguments["attachment_paths"]?.attachmentPathsValue(at: 2)),
                    ("Attachment 4", arguments["attachment_paths"]?.attachmentPathsValue(at: 3)),
                    ("Attachment 5", arguments["attachment_paths"]?.attachmentPathsValue(at: 4)),
                    ("First use", "macOS may ask on your Mac. Choose Allow so Remote Desktop Host can use Mail."),
                ]),
                confirmLabel: sendsNow ? "Send email" : "Create draft")

        case RemoteDesktopCloudStorageMCP.toolName:
            let arguments = call.arguments
            let sourceName = (arguments["source_path"]?.displayValue)
                .map { URL(fileURLWithPath: $0).lastPathComponent }
            let providerID = arguments["provider_id"]?.displayValue
            let providerLabel: String
            if providerID == "icloud-drive" {
                providerLabel = "iCloud Drive"
            } else if let providerID, providerID.hasPrefix("cloudstorage:") {
                providerLabel = String(providerID.dropFirst("cloudstorage:".count))
            } else {
                providerLabel = "Selected cloud folder"
            }
            let folder = arguments["relative_folder"]?.displayValue ?? ""
            let destinationName = (arguments["destination_path"]?.displayValue)
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? sourceName
            let replacing: Bool
            if case .some(.string(_)) = arguments["existing_destination_sha256"] {
                replacing = true
            } else { replacing = false }
            let destination = [providerLabel, folder, destinationName]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " › ")
            return MCPComputerUseApprovalPresentation(
                message: replacing
                    ? "Replace this file in cloud storage?"
                    : "Save a copy to cloud storage?",
                details: Self.details([
                    ("File", sourceName),
                    ("Destination", destination),
                ]),
                confirmLabel: replacing ? "Replace file" : "Save copy")

        case "imessage_send":
            return MCPComputerUseApprovalPresentation(
                message: "Send this message from your Mac?",
                details: Self.details([
                    ("To", arguments["to"]?.displayValue),
                    ("Message", arguments["body"]?.displayValue),
                ]),
                confirmLabel: "Send message")

        case "calendar_create_event":
            return MCPComputerUseApprovalPresentation(
                message: "Add this event to Calendar on your Mac?",
                details: Self.details([
                    ("Event", arguments["summary"]?.displayValue),
                    ("Starts", arguments["start_iso"]?.displayValue),
                    ("Ends", arguments["end_iso"]?.displayValue),
                    ("Calendar", arguments["calendar"]?.displayValue),
                    ("Location", arguments["location"]?.displayValue),
                    ("Notes", arguments["notes"]?.displayValue),
                ]),
                confirmLabel: "Add event")

        case "reminders_create":
            return MCPComputerUseApprovalPresentation(
                message: "Create this reminder on your Mac?",
                details: Self.details([
                    ("Reminder", arguments["title"]?.displayValue),
                    ("List", arguments["list"]?.displayValue),
                    ("Due", arguments["due_iso"]?.displayValue),
                    ("Notes", arguments["notes"]?.displayValue),
                ]),
                confirmLabel: "Create reminder")

        case "run_shortcut":
            return MCPComputerUseApprovalPresentation(
                message: "Run this Shortcut on your Mac?",
                details: Self.details([
                    ("Shortcut", arguments["name"]?.displayValue),
                    ("Input", arguments["input"]?.displayValue),
                ]),
                confirmLabel: "Run shortcut")

        default:
            return MCPComputerUseApprovalPresentation(
                message: display.summary,
                details: [ComputerUseApprovalRequest.Detail(
                    label: "Exact local action",
                    value: call.canonicalArguments)],
                confirmLabel: display.confirmLabel)
        }
    }

    private static func details(
        _ values: [(String, String?)]
    ) -> [ComputerUseApprovalRequest.Detail] {
        values.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return ComputerUseApprovalRequest.Detail(label: label, value: value)
        }
    }
}

private extension MCPJSONValue {
    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    func attachmentPathsValue(at index: Int) -> String? {
        guard case .array(let paths) = self, paths.indices.contains(index),
              case .string(let path) = paths[index] else { return nil }
        return path
    }

    var displayValue: String {
        switch self {
        case .null:
            return ""
        case .bool(let value):
            return value ? "Yes" : "No"
        case .integer(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .string(let value):
            return value
        case .array, .object:
            return (try? String(
                data: MCPDigest.canonicalData(for: self),
                encoding: .utf8)) ?? ""
        }
    }
}
