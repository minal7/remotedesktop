import Foundation
import CryptoKit

/// Full verification snapshots stay local. Model-facing text is a separate,
/// explicit bounded NativeTextState projection of nonprotected UI, never an
/// incidental disclosure through edit verification, approval copy or telemetry.
struct ComputerUseTextSnapshot: Equatable, Sendable {
    let targetID: String
    let value: String
    let selection: NSRange
    let isEditable: Bool
    let isSecure: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.targetID == rhs.targetID && lhs.value.utf8.elementsEqual(rhs.value.utf8)
            && lhs.selection == rhs.selection && lhs.isEditable == rhs.isEditable
            && lhs.isSecure == rhs.isSecure
    }

    var preconditionDigest: String {
        let fields = [targetID, value, String(selection.location),
                      String(selection.length), String(isEditable), String(isSecure)]
        // Length framing keeps field boundaries unambiguous.
        let bytes = fields.reduce(into: Data()) { data, field in
            data.append(Data("\(field.utf8.count):".utf8))
            data.append(Data(field.utf8))
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Explicit, bounded native UI data for choosing the next action. Verification
/// snapshots and target authority remain local; protected values never project.
struct ComputerUseNativeTextState: Equatable, Sendable {
    static let maximumPrefixBytes = 512
    static let maximumObservedValueBytes = 1_024 * 1_024
    let valuePrefix: String
    let valueUTF8Bytes: Int
    let valueUTF16Units: Int
    let selection: NSRange
    let truncated: Bool

    init?(snapshot: ComputerUseTextSnapshot) {
        guard snapshot.isEditable, !snapshot.isSecure else { return nil }
        let bytes = snapshot.value.utf8.count, units = snapshot.value.utf16.count
        guard bytes <= Self.maximumObservedValueBytes,
              snapshot.selection.location >= 0, snapshot.selection.length >= 0,
              snapshot.selection.location <= units, snapshot.selection.length <= units - snapshot.selection.location else { return nil }
        var prefix = "", prefixBytes = 0
        for character in snapshot.value {
            let text = String(character), size = String(character).utf8.count
            guard prefixBytes + size <= Self.maximumPrefixBytes else { break }
            prefix += text; prefixBytes += size
        }
        valuePrefix = prefix; valueUTF8Bytes = bytes; valueUTF16Units = units
        selection = snapshot.selection; truncated = prefixBytes != bytes
    }

    var jsonObject: [String: Any] {
        ["value_prefix": valuePrefix, "value_utf8_bytes": valueUTF8Bytes, "value_utf16_units": valueUTF16Units,
         "value_truncated": truncated, "selection_utf16": ["location": selection.location, "length": selection.length]]
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.valuePrefix.utf8.elementsEqual(rhs.valuePrefix.utf8) && lhs.valueUTF8Bytes == rhs.valueUTF8Bytes
            && lhs.valueUTF16Units == rhs.valueUTF16Units && lhs.selection == rhs.selection && lhs.truncated == rhs.truncated
    }
}
