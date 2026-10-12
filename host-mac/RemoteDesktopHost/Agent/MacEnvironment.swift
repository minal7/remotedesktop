import Foundation

struct AgentMacSnapshot {
    let identity: String
    let bundleID: String
    let title: String
    let screenshot: Data
    let elements: [AgentElement]
    let focus: AgentFocus?
    var authorityDigest: String? = nil
}

@MainActor
protocol AgentMacBackend: AnyObject {
    func snapshot() async throws -> AgentMacSnapshot
    func perform(_ action: AgentAction, snapshot: AgentMacSnapshot) async throws -> String
    func suspend()
    func resume()
    func stop()
}

extension AgentMacBackend {
    func suspend() {}
    func resume() {}
}

/// Window ownership and element semantics are checked again after every suspension.
@MainActor
final class MacEnvironment: AgentEnvironment {
    private let taskID: String
    private let backend: any AgentMacBackend
    private var boundIdentity: String?
    private var lastSnapshot: AgentMacSnapshot?
    private var stopped = false
    private var suspended = false

    init(taskID: String, backend: any AgentMacBackend) {
        self.taskID = taskID; self.backend = backend
    }

    func observe(_ context: AgentObservationContext) async throws -> AgentFrame {
        try checkActive()
        let snapshot = try await backend.snapshot()
        try checkActive()
        if let boundIdentity, boundIdentity != snapshot.identity { throw AgentEnvironmentError.scopeChanged }
        boundIdentity = snapshot.identity
        lastSnapshot = snapshot
        return try frame(snapshot, context: context)
    }

    func resolve(_ action: AgentAction, in old: AgentFrame) async throws -> AgentResolvedAction {
        try checkScope(old.scope)
        let snapshot = try await backend.snapshot()
        try checkScope(old.scope)
        guard snapshot.identity == old.scope.identity else { throw AgentEnvironmentError.scopeChanged }
        let fresh = try frame(snapshot, context: context(old.observation))
        let targets = try AgentTargetBinding.resolve(action, expected: old.observation, fresh: fresh.observation)
        lastSnapshot = snapshot
        return .init(action: action, frame: fresh, targets: targets)
    }

    func execute(_ resolved: AgentResolvedAction) async throws -> AgentExecutionResult {
        try checkScope(resolved.frame.scope)
        let snapshot = try await backend.snapshot()
        try checkScope(resolved.frame.scope)
        guard snapshot.identity == resolved.frame.scope.identity else { throw AgentEnvironmentError.scopeChanged }
        let fresh = try frame(snapshot, context: context(resolved.frame.observation))
        _ = try AgentTargetBinding.resolve(resolved.action, expected: resolved.frame.observation, fresh: fresh.observation)
        guard AgentTargetBinding.samePayload(resolved.frame.observation, fresh.observation) else {
            throw AgentEnvironmentError.targetChanged
        }
        guard resolved.frame.authorityDigest == fresh.authorityDigest else {
            throw AgentEnvironmentError.targetChanged
        }
        let result = try await backend.perform(resolved.action, snapshot: snapshot)
        try checkActive()
        if case .openApp = resolved.action { boundIdentity = nil }
        return .init(status: .ok, result: result)
    }

    func stop() async { stopped = true; backend.stop() }
    func suspend() async { suspended = true; backend.suspend() }
    func resume() async throws {
        guard !stopped else { throw CancellationError() }
        backend.resume(); suspended = false
    }

    private func frame(_ snapshot: AgentMacSnapshot, context: AgentObservationContext) throws -> AgentFrame {
        let observation = AgentObservation(task: context.task, surface: .app(bundleID: snapshot.bundleID, title: snapshot.title),
            screenshot: snapshot.screenshot.base64EncodedString(), elements: snapshot.elements, focus: snapshot.focus,
            history: context.history, budget: context.budget)
        try observation.validate()
        return .init(observation: observation, scope: .init(taskID: taskID, kind: .app, identity: snapshot.identity),
                     authorityDigest: snapshot.authorityDigest)
    }

    private func context(_ observation: AgentObservation) -> AgentObservationContext {
        .init(task: observation.task, history: observation.history, budget: observation.budget)
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !stopped, !suspended else { throw CancellationError() }
    }

    private func checkScope(_ scope: AgentScope) throws {
        try checkActive()
        guard scope.taskID == taskID, scope.kind == .app, scope.identity == boundIdentity else {
            throw AgentEnvironmentError.scopeChanged
        }
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

    static func resolve(_ action: AgentAction, expected: AgentObservation,
                        fresh: AgentObservation) throws -> [AgentElement] {
        var targets = try targets(action).compactMap { target -> AgentElement? in
            switch target {
            case let .element(id):
                guard let old = expected.elements.first(where: { $0.id == id }),
                      let current = fresh.elements.first(where: { $0.id == id }) else { throw AgentEnvironmentError.targetGone }
                try rebind(old, current); return current
            case let .point(x, y):
                let old = hit(x: x, y: y, elements: expected.elements)
                let current = hit(x: x, y: y, elements: fresh.elements)
                if let old, let current { try rebind(old, current) }
                else if old != nil || current != nil { throw AgentEnvironmentError.targetChanged }
                return current
            }
        }
        switch action {
        case .type(nil, _, _), .key:
            guard let before = expected.focus, let after = fresh.focus,
                  before.id == after.id, before.role == after.role, before.name == after.name else {
                throw AgentEnvironmentError.targetChanged
            }
            if let old = expected.elements.first(where: { $0.id == before.id }),
               let current = fresh.elements.first(where: { $0.id == after.id }) {
                try rebind(old, current); targets.append(current)
            }
        default: break
        }
        return targets
    }

    static func rebind(_ old: AgentElement, _ fresh: AgentElement) throws {
        guard old.id == fresh.id, old.role == fresh.role, old.name == fresh.name else { throw AgentEnvironmentError.targetChanged }
        guard fresh.inView else { throw AgentEnvironmentError.targetCovered }
        guard !fresh.state.contains("covered") else { throw AgentEnvironmentError.targetCovered }
        guard !fresh.state.contains("disabled") else { throw AgentEnvironmentError.disabledTarget }
    }

    static func hit(x: Double, y: Double, elements: [AgentElement]) -> AgentElement? {
        elements.filter { element in
            let b = element.bbox
            return element.inView && x >= b.x && y >= b.y && x < b.x + b.width && y < b.y + b.height
        }.min { $0.bbox.width * $0.bbox.height < $1.bbox.width * $1.bbox.height }
    }

    static func samePayload(_ old: AgentObservation, _ fresh: AgentObservation) -> Bool {
        guard old.surface == fresh.surface, old.focus?.id == fresh.focus?.id else { return false }
        let previous = old.elements.filter { $0.value != nil }.map { "\($0.id)|\($0.role)|\($0.name)|\($0.value ?? "")" }.sorted()
        let current = fresh.elements.filter { $0.value != nil }.map { "\($0.id)|\($0.role)|\($0.name)|\($0.value ?? "")" }.sorted()
        return previous == current
    }
}
