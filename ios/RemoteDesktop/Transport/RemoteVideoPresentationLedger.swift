import Foundation

/// Local decoded-frame identity only. This is not a source-capture witness.
struct RemoteVideoPresentationTicket: Hashable, Sendable {
    let id = UUID()
    let context: UUID
    let frame: UUID
    let drawable: ObjectIdentifier
    let drawableID: Int
}

/// A receipt requires both successful GPU completion and a non-skipped
/// presentation of the exact drawable. Observation expiry cannot free work
/// that the GPU has not actually finished.
struct RemoteVideoPresentationLedger {
    enum Result: Equatable, Sendable {
        case presented(TimeInterval)
        case skipped
        case failed
        case expired
    }
    struct Change {
        var results: [(RemoteVideoPresentationTicket, Result)] = []
        var released: [RemoteVideoPresentationTicket] = []
        var silenced: [RemoteVideoPresentationTicket] = []
    }
    private struct Entry {
        let ticket: RemoteVideoPresentationTicket
        var committed = false
        var gpuSucceeded: Bool?
        var presentation: TimeInterval?
        var retired = false
    }
    let capacity: Int
    private var entries: [UUID: Entry] = [:]
    var count: Int { entries.count }

    init(capacity: Int = 2) { self.capacity = max(1, capacity) }

    mutating func reserve(context: UUID, frame: UUID, drawable: ObjectIdentifier,
                          drawableID: Int) -> RemoteVideoPresentationTicket? {
        guard entries.count < capacity, drawableID >= 0,
              !entries.values.contains(where: { $0.ticket.drawable == drawable }) else { return nil }
        let ticket = RemoteVideoPresentationTicket(context: context, frame: frame, drawable: drawable, drawableID: drawableID)
        entries[ticket.id] = Entry(ticket: ticket)
        return ticket
    }

    mutating func commit(_ ticket: RemoteVideoPresentationTicket) -> Bool {
        guard var entry = entries[ticket.id], entry.ticket == ticket,
              !entry.retired, !entry.committed else { return false }
        entry.committed = true
        entries[ticket.id] = entry
        return true
    }

    mutating func completeGPU(_ ticket: RemoteVideoPresentationTicket, succeeded: Bool) -> Change {
        guard var entry = entries[ticket.id], entry.ticket == ticket, entry.committed,
              entry.gpuSucceeded == nil else { return Change() }
        entry.gpuSucceeded = succeeded
        entries[ticket.id] = entry
        return settle(ticket)
    }

    mutating func presented(_ ticket: RemoteVideoPresentationTicket, drawable: ObjectIdentifier,
                            drawableID: Int, time: TimeInterval) -> Change {
        guard var entry = entries[ticket.id], entry.ticket == ticket, entry.committed,
              ticket.drawable == drawable, ticket.drawableID == drawableID,
              entry.presentation == nil else { return Change() }
        entry.presentation = time.isFinite && time > 0 ? time : 0
        entries[ticket.id] = entry
        return settle(ticket)
    }

    mutating func abandonUncommitted(_ ticket: RemoteVideoPresentationTicket) -> Change {
        guard let entry = entries[ticket.id], entry.ticket == ticket, !entry.committed else { return Change() }
        entries.removeValue(forKey: ticket.id)
        return Change(released: [ticket])
    }

    mutating func retire(context: UUID) -> Change {
        var change = Change()
        for ticket in entries.values.map(\.ticket) where ticket.context == context {
            guard var entry = entries[ticket.id] else { continue }
            entry.retired = true
            entries[ticket.id] = entry
            change.silenced.append(ticket)
            let settled = settle(ticket)
            change.released += settled.released
        }
        return change
    }

    mutating func expire(_ ticket: RemoteVideoPresentationTicket) -> Change {
        guard var entry = entries[ticket.id], entry.ticket == ticket, !entry.retired else { return Change() }
        entry.retired = true
        entries[ticket.id] = entry
        var change = settle(ticket)
        change.results.append((ticket, .expired))
        return change
    }

    private mutating func settle(_ ticket: RemoteVideoPresentationTicket) -> Change {
        guard let entry = entries[ticket.id] else { return Change() }
        if entry.retired {
            guard !entry.committed || entry.gpuSucceeded != nil else { return Change() }
            entries.removeValue(forKey: ticket.id)
            return Change(released: [ticket])
        }
        guard let succeeded = entry.gpuSucceeded else { return Change() }
        if !succeeded {
            entries.removeValue(forKey: ticket.id)
            return Change(results: [(ticket, .failed)], released: [ticket])
        }
        guard let time = entry.presentation else { return Change() }
        entries.removeValue(forKey: ticket.id)
        return Change(results: [(ticket, time > 0 ? .presented(time) : .skipped)], released: [ticket])
    }
}

/// Shared across producer instances, including retired surfaces. No permit is
/// released merely because an observer timed out or a view disappeared.
@MainActor
final class RemoteVideoPresentationBudget {
    static let shared = RemoteVideoPresentationBudget()
    private var ledger = RemoteVideoPresentationLedger()
    private var callbacks: [UUID: @MainActor (RemoteVideoPresentationLedger.Result) -> Void] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]

    func reserve(context: UUID, frame: UUID, drawable: ObjectIdentifier, drawableID: Int,
                 onResult: @escaping @MainActor (RemoteVideoPresentationLedger.Result) -> Void) -> RemoteVideoPresentationTicket? {
        guard let ticket = ledger.reserve(context: context, frame: frame, drawable: drawable, drawableID: drawableID) else { return nil }
        callbacks[ticket.id] = onResult
        // Provisional observation bound; it does not cancel native GPU work.
        deadlines[ticket.id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self else { return }
            self.apply(self.ledger.expire(ticket))
        }
        return ticket
    }

    func commit(_ ticket: RemoteVideoPresentationTicket) -> Bool { ledger.commit(ticket) }
    func abandonUncommitted(_ ticket: RemoteVideoPresentationTicket) { apply(ledger.abandonUncommitted(ticket)) }
    func retire(context: UUID) { apply(ledger.retire(context: context)) }
    func completeGPU(_ ticket: RemoteVideoPresentationTicket, succeeded: Bool) { apply(ledger.completeGPU(ticket, succeeded: succeeded)) }
    func presented(_ ticket: RemoteVideoPresentationTicket, drawable: ObjectIdentifier, drawableID: Int, time: TimeInterval) {
        apply(ledger.presented(ticket, drawable: drawable, drawableID: drawableID, time: time))
    }

    private func apply(_ change: RemoteVideoPresentationLedger.Change) {
        // Remove registrations before any user callback can reenter reserve.
        let deliveries = change.results.compactMap { ticket, result in
            callbacks.removeValue(forKey: ticket.id).map { ($0, result) }
        }
        for ticket in change.released + change.silenced {
            callbacks.removeValue(forKey: ticket.id)
            deadlines.removeValue(forKey: ticket.id)?.cancel()
        }
        for (ticket, _) in change.results { deadlines.removeValue(forKey: ticket.id)?.cancel() }
        for (callback, result) in deliveries { callback(result) }
    }
}
