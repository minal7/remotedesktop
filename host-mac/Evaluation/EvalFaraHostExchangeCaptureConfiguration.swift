#if DEBUG
import Foundation

/// Identity passed from the local evaluator to bind HTTP capture to one task run.
struct EvalFaraHostExchangeCaptureConfiguration: Sendable, Equatable {
    let caseID: String
    let runToken: String
    let driverTaskID: String
    let runRoot: String
}
#endif
