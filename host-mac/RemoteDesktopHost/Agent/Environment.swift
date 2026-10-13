import Foundation

/// Host authority is separate from the model-facing observation.
struct AgentScope: Equatable {
    enum Kind: String { case web, app }
    let taskID: String
    let kind: Kind
    let identity: String
}

struct AgentObservationContext {
    let task: String
    let history: [AgentHistoryItem]
    let budget: AgentStepBudget
}

struct AgentFrame {
    let observation: AgentObservation
    let scope: AgentScope
    /// Complete nonsecure payload digest, computed by the host adapter before model truncation.
    /// This authority metadata is deliberately absent from the policy observation schema.
    var authorityDigest: String? = nil
}

/// Freshly resolved targets and surface identity, never authority supplied by a model.
struct AgentResolvedAction {
    let action: AgentAction
    let frame: AgentFrame
    let targets: [AgentElement]
    /// Host-only context for this gate decision; never serialized to the model.
    var targetContextLabel: String? = nil
    /// True when the current surface is deliberately read-only, even without AX marks.
    var surfaceReadOnly: Bool = false
}

@MainActor
protocol AgentEnvironment: AnyObject {
    /// Pixel input follows the frontmost surface, whose window identity may change between frames.
    var followsFrontmostSurface: Bool { get }
    func observe(_ context: AgentObservationContext) async throws -> AgentFrame
    /// Re-observe and resolve element identities; reject gone/changed/covered targets.
    func resolve(_ action: AgentAction, in frame: AgentFrame) async throws -> AgentResolvedAction
    /// Rebind the already approved semantic target to a fresh observation.
    func rebind(_ resolved: AgentResolvedAction, in frame: AgentFrame) async throws -> AgentResolvedAction
    /// Recheck the resolved scope at the final input boundary, including cancellation.
    func execute(_ resolved: AgentResolvedAction) async throws -> AgentExecutionResult
    func suspend() async
    func resume() async throws
    func stop() async
}

extension AgentEnvironment {
    var followsFrontmostSurface: Bool { false }
    func rebind(_ resolved: AgentResolvedAction, in frame: AgentFrame) async throws -> AgentResolvedAction {
        try await resolve(resolved.action, in: frame)
    }
    func suspend() async {}
    func resume() async throws {}
}

enum AgentEnvironmentError: Error, Equatable {
    case unavailable(String), scopeChanged, targetGone, targetChanged, targetCovered
    case disabledTarget, unsupportedAction, credentialHandoff, systemHandoff(String)
}
