import Foundation
import CryptoKit

/// These values stay inside the host. Field contents never become model
/// observations, approval copy, or telemetry merely to verify an edit.
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

enum ComputerUseTextEditMode: String, Codable, Sendable { case insert, replaceAll, append }

enum ComputerUseTextEditError: Error, Equatable, LocalizedError {
    case unavailableTarget, secureTarget, invalidSelection, payloadTooLarge, valueNotRepresentable
    case preconditionChanged, selectionUnsupported, deliveryUncertain, interrupted, deadlineExceeded

    var errorDescription: String? {
        switch self {
        case .unavailableTarget:
            return "The focused field does not expose a readable, editable value. No text was entered."
        case .secureTarget:
            return "Enter protected text yourself in the app."
        case .invalidSelection:
            return "The app's text selection could not be verified. No text was entered."
        case .payloadTooLarge:
            return "This edit exceeds the supported text size. No text was entered."
        case .valueNotRepresentable:
            return "That field cannot accept the exact requested value. Check its format, range or allowed increments. This edit was not sent."
        case .preconditionChanged:
            return "The field, document, value, or selection changed before typing. No text was entered."
        case .selectionUnsupported:
            return "The app did not accept the required text selection. No text was entered."
        case .deliveryUncertain:
            return "The app did not confirm the exact text edit. Check the field before continuing; the edit was not retried."
        case .interrupted:
            return "Text entry was interrupted. Check the current field before continuing."
        case .deadlineExceeded:
            return "Text entry reached its time limit. Check the current field before continuing; the edit was not retried."
        }
    }
}

/// A small transaction over a specific editable field. An emitted event is
/// only an attempted effect; exact readback is required before success or the
/// next Unicode stroke. There is deliberately no retry of a possibly delivered
/// stroke, even when the app has not yet exposed its resulting value.
@MainActor
struct ComputerUseTextEditor {
    nonisolated static let maximumPayloadBytes = 64 * 1_024
    nonisolated static let maximumObservedValueBytes = 1_024 * 1_024
    nonisolated static let defaultMaximumDuration: TimeInterval = 60

    let read: () throws -> ComputerUseTextSnapshot?
    let select: (NSRange, ComputerUseTextSnapshot) throws -> Bool
    /// nil means unsupported and guarantees that no setter was invoked.
    let replaceSelectedText: (String, ComputerUseTextSnapshot) throws -> Bool?
    /// Receives exactly one extended grapheme and its full pre-effect state.
    /// A provider must check that state at the key-down admission boundary.
    let postUnicode: (String, ComputerUseTextSnapshot) async throws -> Void
    let mayAct: () -> Bool
    var wait: () async throws -> Void = {
        try await Task.sleep(for: .milliseconds(25))
    }
    var verificationAttempts = 12
    var maximumDuration: TimeInterval = ComputerUseTextEditor.defaultMaximumDuration
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Optional qualified whole-value setter. nil result guarantees no setter
    /// was invoked; a returned failure must still be verified, never retried.
    var replaceValue: ((String, ComputerUseTextSnapshot) throws -> Bool?)? = nil
    /// Other fields required by a task, excluding this edit's evolving value.
    /// Native input also checks these requirements inside its effect gate.
    var validateContext: () throws -> Void = {}

    func edit(
        _ payload: String,
        mode: ComputerUseTextEditMode = .insert,
        expected initial: ComputerUseTextSnapshot
    ) async throws {
        let deadline = uptime() + maximumDuration
        guard payload.utf8.count <= Self.maximumPayloadBytes,
              initial.value.utf8.count <= Self.maximumObservedValueBytes else {
            throw ComputerUseTextEditError.payloadTooLarge
        }
        guard !initial.isSecure else { throw ComputerUseTextEditError.secureTarget }
        guard initial.isEditable else { throw ComputerUseTextEditError.unavailableTarget }
        await Task.yield()
        guard !Task.isCancelled, mayAct() else {
            throw ComputerUseTextEditError.interrupted
        }
        guard uptime() < deadline else { throw ComputerUseTextEditError.deadlineExceeded }
        guard try read() == initial else {
            throw ComputerUseTextEditError.preconditionChanged
        }
        let range: NSRange
        switch mode {
        case .insert: range = initial.selection
        case .replaceAll: range = NSRange(location: 0, length: initial.value.utf16.count)
        case .append: range = NSRange(location: initial.value.utf16.count, length: 0)
        }
        guard let swiftRange = Range(range, in: initial.value) else {
            throw ComputerUseTextEditError.invalidSelection
        }
        let expectedValue = initial.value.replacingCharacters(in: swiftRange, with: payload)
        guard expectedValue.utf8.count <= Self.maximumObservedValueBytes else {
            throw ComputerUseTextEditError.payloadTooLarge
        }
        try requireEffectAuthority(expected: initial, deadline: deadline)
        if let replaceValue, try replaceValue(expectedValue, initial) != nil {
            _ = try await verify(value: expectedValue, target: initial.targetID, deadline: deadline)
            return
        }
        var selected = initial
        if range != initial.selection {
            try requireEffectAuthority(expected: initial, deadline: deadline)
            guard try select(range, initial) else {
                throw ComputerUseTextEditError.selectionUnsupported
            }
            guard let current = try read(), current.targetID == initial.targetID,
                  current.value.utf8.elementsEqual(initial.value.utf8), current.selection == range,
                  current.isEditable, !current.isSecure else {
                throw ComputerUseTextEditError.selectionUnsupported
            }
            selected = current
        }
        try requireEffectAuthority(expected: selected, deadline: deadline)
        // Prefer the reviewed AX selected-text setter when supported. An AX
        // error does not prove absence of an effect, so do not fall back after
        // invoking it; only read back and classify the outcome.
        if try replaceSelectedText(payload, selected) != nil {
            _ = try await verify(value: expectedValue, target: initial.targetID, deadline: deadline)
            return
        }
        guard !payload.isEmpty else {
            // Even an empty/no-op edit requires a supported setter. Returning
            // success here would invent an input receipt without dispatching
            // anything; an empty Unicode call cannot prove an operation.
            throw ComputerUseTextEditError.selectionUnsupported
        }
        var remaining = payload[...]
        while !remaining.isEmpty {
            await Task.yield()
            guard !Task.isCancelled, mayAct() else {
                throw ComputerUseTextEditError.interrupted
            }
            guard uptime() < deadline else { throw ComputerUseTextEditError.deadlineExceeded }
            guard try read() == selected else {
                throw ComputerUseTextEditError.deliveryUncertain
            }
            // CGEvent delivery suspends between graphemes. Reading only after
            // a larger string lets a same-field caret/value change redirect
            // subsequent keys before the mismatch is detected.
            let chunk = String(remaining.prefix(1))
            remaining = remaining.dropFirst()
            guard let selectionRange = Range(selected.selection, in: selected.value) else {
                throw ComputerUseTextEditError.deliveryUncertain
            }
            let nextValue = selected.value.replacingCharacters(in: selectionRange, with: chunk)
            let nextCaret = selected.selection.location + chunk.utf16.count
            try requireEffectAuthority(expected: selected, deadline: deadline, valueMayHaveChanged: true)
            try await postUnicode(chunk, selected)
            selected = try await verify(value: nextValue, target: initial.targetID, deadline: deadline)
            if !remaining.isEmpty,
               selected.selection != NSRange(location: nextCaret, length: 0) {
                throw ComputerUseTextEditError.deliveryUncertain
            }
        }
    }

    private func requireEffectAuthority(expected: ComputerUseTextSnapshot, deadline: TimeInterval,
                                        valueMayHaveChanged: Bool = false) throws {
        guard !Task.isCancelled, mayAct() else { throw ComputerUseTextEditError.interrupted }
        guard uptime() < deadline else { throw ComputerUseTextEditError.deadlineExceeded }
        try validateContext()
        guard try read() == expected else {
            throw valueMayHaveChanged ? ComputerUseTextEditError.deliveryUncertain : .preconditionChanged
        }
        // Context and AX reads can take time or observe a revoked owner.
        guard !Task.isCancelled, mayAct() else { throw ComputerUseTextEditError.interrupted }
        guard uptime() < deadline else { throw ComputerUseTextEditError.deadlineExceeded }
    }

    private func verify(value: String, target: String, deadline: TimeInterval) async throws -> ComputerUseTextSnapshot {
        for attempt in 0 ..< max(1, verificationAttempts) {
            guard !Task.isCancelled, mayAct() else {
                throw ComputerUseTextEditError.interrupted
            }
            guard uptime() < deadline else { throw ComputerUseTextEditError.deadlineExceeded }
            try validateContext()
            guard let current = try read(), current.targetID == target,
                  current.isEditable, !current.isSecure else {
                throw ComputerUseTextEditError.deliveryUncertain
            }
            // Context/AX reads can suspend progress or invalidate ownership.
            // An exact value read after Stop or the deadline is not success.
            guard !Task.isCancelled, mayAct() else { throw ComputerUseTextEditError.interrupted }
            guard uptime() < deadline else { throw ComputerUseTextEditError.deadlineExceeded }
            // No implicit Unicode normalization: an app-specific relaxation
            // must be explicit, rather than Swift String's canonical equality.
            if current.value.utf8.elementsEqual(value.utf8) { return current }
            if attempt + 1 < max(1, verificationAttempts) { try await wait() }
        }
        throw ComputerUseTextEditError.deliveryUncertain
    }
}
