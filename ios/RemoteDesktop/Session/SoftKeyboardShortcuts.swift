import Foundation

enum SoftModifier: CaseIterable, Hashable {
    case cmd
    case opt
    case ctrl
    case shift

    var symbol: String {
        switch self {
        case .cmd: return "⌘"
        case .opt: return "⌥"
        case .ctrl: return "⌃"
        case .shift: return "⇧"
        }
    }

    var hidUsage: Int {
        switch self {
        case .shift: return 0xE1
        case .ctrl: return 0xE0
        case .opt: return 0xE2
        case .cmd: return 0xE3
        }
    }

    var mask: UInt16 {
        switch self {
        case .shift: return UInt16(1 << 0)
        case .ctrl: return UInt16(1 << 1)
        case .opt: return UInt16(1 << 2)
        case .cmd: return UInt16(1 << 3)
        }
    }
}

struct SoftKeyboardShortcut {
    let usage: Int
    let modifiers: UInt16
}

enum SoftKeyboardShortcutMapper {
    static func map(_ string: String, baseModifiers: UInt16) -> SoftKeyboardShortcut? {
        guard string.count == 1, let scalar = string.unicodeScalars.first, scalar.isASCII else {
            return nil
        }
        let char = Character(string)

        if char.isLetter {
            let lower = Character(string.lowercased())
            guard let ascii = lower.asciiValue else { return nil }
            let usage = Int(0x04 + (ascii - Character("a").asciiValue!))
            let extra = char.isUppercase ? SoftModifier.shift.mask : 0
            return SoftKeyboardShortcut(usage: usage, modifiers: baseModifiers | extra)
        }

        if let mapped = punctuation[char] {
            return SoftKeyboardShortcut(usage: mapped.usage, modifiers: baseModifiers | mapped.extraModifiers)
        }

        guard let ascii = char.asciiValue else { return nil }
        switch char {
        case "1"..."9":
            return SoftKeyboardShortcut(
                usage: Int(0x1E + (ascii - Character("1").asciiValue!)),
                modifiers: baseModifiers)
        case "0":
            return SoftKeyboardShortcut(usage: 0x27, modifiers: baseModifiers)
        default:
            return nil
        }
    }

    private static let punctuation: [Character: (usage: Int, extraModifiers: UInt16)] = [
        " ": (0x2C, 0),
        "-": (0x2D, 0),
        "_": (0x2D, SoftModifier.shift.mask),
        "=": (0x2E, 0),
        "+": (0x2E, SoftModifier.shift.mask),
        "[": (0x2F, 0),
        "{": (0x2F, SoftModifier.shift.mask),
        "]": (0x30, 0),
        "}": (0x30, SoftModifier.shift.mask),
        "\\": (0x31, 0),
        "|": (0x31, SoftModifier.shift.mask),
        ";": (0x33, 0),
        ":": (0x33, SoftModifier.shift.mask),
        "'": (0x34, 0),
        "\"": (0x34, SoftModifier.shift.mask),
        "`": (0x35, 0),
        "~": (0x35, SoftModifier.shift.mask),
        ",": (0x36, 0),
        "<": (0x36, SoftModifier.shift.mask),
        ".": (0x37, 0),
        ">": (0x37, SoftModifier.shift.mask),
        "/": (0x38, 0),
        "?": (0x38, SoftModifier.shift.mask),
        "!": (0x1E, SoftModifier.shift.mask),
        "@": (0x1F, SoftModifier.shift.mask),
        "#": (0x20, SoftModifier.shift.mask),
        "$": (0x21, SoftModifier.shift.mask),
        "%": (0x22, SoftModifier.shift.mask),
        "^": (0x23, SoftModifier.shift.mask),
        "&": (0x24, SoftModifier.shift.mask),
        "*": (0x25, SoftModifier.shift.mask),
        "(": (0x26, SoftModifier.shift.mask),
        ")": (0x27, SoftModifier.shift.mask),
    ]
}
