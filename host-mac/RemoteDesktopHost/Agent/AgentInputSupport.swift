import Foundation

enum AgentFileResults {
    static func render(_ candidates: [AgentFileCandidate]) throws -> String {
        let object: [[String: Any]] = candidates.map {
            ["id": $0.id, "name": $0.name, "kind": $0.kind as Any? ?? NSNull(),
             "modified_at": $0.modifiedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["candidates": object], options: [.sortedKeys]), as: UTF8.self)
    }
}

struct AgentKeyStroke: Equatable {
    let usage: Int
    let modifiers: UInt16

    static func parse(_ chord: String) throws -> Self {
        let rawParts: [String]
        if chord == " " { rawParts = ["space"] }
        else if chord.hasSuffix("+ ") {
            rawParts = chord.dropLast(2).split(separator: "+", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) } + ["space"]
        } else if chord == "+" { rawParts = ["+"] }
        else if chord.hasSuffix("++") {
            let prefix = String(chord.dropLast())
            rawParts = Array(prefix.split(separator: "+", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }.dropLast()) + ["+"]
        } else {
            rawParts = chord.split(separator: "+", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard let rawKey = rawParts.last, !rawKey.isEmpty else {
            throw AgentEnvironmentError.unavailable("Unsupported key or modifier.")
        }
        let key = rawKey.lowercased()
        let modifierNames: [String: UInt16] = ["cmd": 8, "command": 8, "meta": 8, "super": 8,
            "ctrl": 2, "control": 2, "shift": 1, "alt": 4, "opt": 4, "option": 4]
        var modifiers: UInt16 = 0
        for rawPart in rawParts.dropLast() {
            guard let mask = modifierNames[rawPart.lowercased()] else {
                throw AgentEnvironmentError.unavailable("Unsupported key or modifier.")
            }
            modifiers |= mask
        }
        let named: [String: Int] = ["enter": 0x28, "return": 0x28, "escape": 0x29, "esc": 0x29, "backspace": 0x2a,
            "tab": 0x2b, "space": 0x2c, "delete": 0x2a, "forwarddelete": 0x4c, "del": 0x4c,
            "home": 0x4a, "end": 0x4d, "pageup": 0x4b,
            "pagedown": 0x4e, "arrowright": 0x4f, "right": 0x4f, "arrowleft": 0x50, "left": 0x50,
            "arrowdown": 0x51, "down": 0x51, "arrowup": 0x52, "up": 0x52]
        let scalar = key.unicodeScalars.count == 1 ? key.unicodeScalars.first?.value : nil
        let originalScalar = rawKey.unicodeScalars.count == 1 ? rawKey.unicodeScalars.first?.value : nil
        let shifted: [UInt32: Int] = [
            33: 0x1e, 64: 0x1f, 35: 0x20, 36: 0x21, 37: 0x22, 94: 0x23, 38: 0x24,
            42: 0x25, 40: 0x26, 41: 0x27, 95: 0x2d, 43: 0x2e, 123: 0x2f, 125: 0x30,
            124: 0x31, 58: 0x33, 34: 0x34, 126: 0x35, 60: 0x36, 62: 0x37, 63: 0x38,
        ]
        var usage: Int?
        if let value = scalar, (97...122).contains(value) {
            usage = Int(value - 97) + 4
            if let originalScalar, (65...90).contains(originalScalar) { modifiers |= 1 }
        }
        else if let value = scalar, (49...57).contains(value) { usage = Int(value - 49) + 0x1e }
        else if key == "0" { usage = 0x27 }
        else if let value = scalar, let baseUsage = shifted[value] { usage = baseUsage; modifiers |= 1 }
        else if let value = scalar {
            let unshifted: [UInt32: Int] = [45: 0x2d, 61: 0x2e, 91: 0x2f, 93: 0x30, 92: 0x31,
                59: 0x33, 39: 0x34, 96: 0x35, 44: 0x36, 46: 0x37, 47: 0x38]
            usage = unshifted[value]
        } else if key == "plus" { usage = 0x2e; modifiers |= 1 }
        else if key.first == "f", let number = Int(key.dropFirst()), (1...20).contains(number) {
            usage = number <= 12 ? 0x39 + number : 0x68 + number - 13
        } else { usage = named[key] }
        guard let usage, HIDUsage.toMacKeyCode(usage) != nil else {
            throw AgentEnvironmentError.unavailable("Unsupported key or modifier.")
        }
        return .init(usage: usage, modifiers: modifiers)
    }
}

enum AgentTargetBinding {
    static func targets(_ action: AgentAction) -> [AgentTarget] {
        switch action {
        case let .click(target, _, _), let .type(target?, _, _), let .scroll(target?, _, _),
             let .select(target, _), let .setFiles(target, _): [target]
        case let .drag(from, to): [from, to]
        default: []
        }
    }

    static func hit(x: Double, y: Double, elements: [AgentElement]) -> AgentElement? {
        elements.filter { element in
            let b = element.bbox
            return element.inView && x >= b.x && y >= b.y && x < b.x + b.width && y < b.y + b.height
        }.min { $0.bbox.width * $0.bbox.height < $1.bbox.width * $1.bbox.height }
    }
}
