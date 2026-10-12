import Foundation

/// Cumulative driver-active time, not wall time or a measure of model/GPU
/// lifetime. Native stages admitted before expiry keep their cleanup/receipts.
/// Only explicit execution segments charge time; manual handback is outside.
@MainActor
final class ComputerUseBrowserWorkBudget {
    nonisolated static let defaultAllowance: Duration = .seconds(600)
    nonisolated static let maximumAllowance: Duration = .seconds(3_600)
    enum Failure: Error, Equatable, LocalizedError {
        case exhausted, invalidAllowance, alreadyActive
        var errorDescription: String? {
            switch self {
            case .exhausted:
                return "The browser reached this task's research time limit. The original request remains pending. You can continue manually; Resume does not extend this limit."
            case .invalidAllowance: return "Browser research could not start because its research time limit was invalid."
            case .alreadyActive: return "The browser is already working on this research task."
            }
        }
    }
    private let allowance: Duration
    private let clock: @MainActor () -> ContinuousClock.Instant
    private var remaining: Duration
    private var activeAt: ContinuousClock.Instant?

    init(allowance: Duration = ComputerUseBrowserWorkBudget.defaultAllowance, clock: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.allowance = allowance; remaining = allowance; self.clock = clock
    }
    func begin() throws {
        guard activeAt == nil else { throw Failure.alreadyActive }
        guard allowance > .zero, allowance <= Self.maximumAllowance else { throw Failure.invalidAllowance }
        guard remaining > .zero else { throw Failure.exhausted }
        activeAt = clock()
    }
    func finish() {
        chargeActiveTime()
        activeAt = nil
    }
    func admit() throws {
        guard activeAt != nil else { throw Failure.exhausted }
        chargeActiveTime()
        guard remaining > .zero else { throw Failure.exhausted }
    }
    /// Direct owner inspection/handback does not open an autonomous segment.
    /// The driver owns begin/finish; a late model callback cannot refill it.
    func planningTimeout(maximum: TimeInterval) throws -> TimeInterval {
        guard maximum.isFinite, maximum > 0, maximum <= ComputerUsePlanningWorker.maximumWait else {
            throw ComputerUsePlanningWorker.Failure.invalidDeadline
        }
        guard allowance > .zero, allowance <= Self.maximumAllowance else { throw Failure.invalidAllowance }
        chargeActiveTime()
        guard remaining > .zero else { throw Failure.exhausted }
        return min(maximum, Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18)
    }
    private func chargeActiveTime() {
        guard let previous = activeAt else { return }
        let current = clock()
        // A faulty injected clock must not refund already consumed work.
        if current < previous { remaining = .zero }
        else { remaining = max(.zero, remaining - previous.duration(to: current)) }
        activeAt = current
    }
}
