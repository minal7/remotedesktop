import Foundation

/// Surface changes are explicit actions. User wording never selects an adapter.
@MainActor
final class AgentEnvironments: AgentEnvironment {
    typealias WebFactory = @MainActor (String) throws -> any AgentEnvironment
    typealias MacFactory = @MainActor () throws -> any AgentEnvironment
    typealias AppOpener = @MainActor (String) async throws -> Void
    private var current: any AgentEnvironment
    private let makeWeb: WebFactory
    private let makeMac: MacFactory
    private let openApp: AppOpener
    private var retired: [any AgentEnvironment] = []
    /// A task-opened tab is kept alive while the task temporarily switches to an app.
    private var cachedWeb: (any AgentEnvironment)?
    private var cachedWebScope: AgentScope?
    private var stopped = false
    private var suspended = false

    init(start: any AgentEnvironment, makeWeb: @escaping WebFactory,
         makeMac: @escaping MacFactory, openApp: @escaping AppOpener) {
        current = start; self.makeWeb = makeWeb; self.makeMac = makeMac; self.openApp = openApp
    }

    func observe(_ context: AgentObservationContext) async throws -> AgentFrame {
        try checkActive()
        let frame = try await current.observe(context)
        if cachedWeb == nil, frame.scope.kind == .web {
            cachedWeb = current
            cachedWebScope = frame.scope
        }
        return frame
    }

    func resolve(_ action: AgentAction, in frame: AgentFrame) async throws -> AgentResolvedAction {
        try checkActive()
        // Validate the old surface before an approved change can claim another one.
        return try await current.resolve(action, in: frame)
    }

    func execute(_ resolved: AgentResolvedAction) async throws -> AgentExecutionResult {
        try checkActive()
        switch (resolved.action, resolved.frame.scope.kind) {
        case let (.openURL(url), .app):
            try await recheckOldScope(resolved)
            if let cachedWeb {
                let fresh = try await cachedWeb.observe(context(resolved.frame.observation))
                try validateReusedWebScope(fresh.scope, taskID: resolved.frame.scope.taskID)
                let navigation = try await cachedWeb.resolve(.openURL(url: url), in: fresh)
                let result = try await cachedWeb.execute(navigation)
                guard result.status == .ok else { throw AgentEnvironmentError.unavailable(result.result) }
                let after = try await cachedWeb.observe(context(resolved.frame.observation))
                try validateReusedWebScope(after.scope, taskID: resolved.frame.scope.taskID)
                try checkActive()
                if current !== cachedWeb { retired.append(current) }
                current = cachedWeb
            } else {
                let next = try makeWeb(url)
                do {
                    let opened = try await next.observe(context(resolved.frame.observation))
                    guard opened.scope.taskID == resolved.frame.scope.taskID,
                          opened.scope.kind == .web else { throw AgentEnvironmentError.scopeChanged }
                    try checkActive()
                    retired.append(current); current = next; cachedWeb = next
                    cachedWebScope = opened.scope
                } catch {
                    await next.stop()
                    throw error
                }
            }
            return .init(status: .ok, result: "Opened a bound task tab.")
        case let (.openApp(name), .web):
            try await recheckOldScope(resolved)
            try await openApp(name)
            try checkActive()
            let next = try makeMac()
            do {
                let opened = try await next.observe(context(resolved.frame.observation))
                guard opened.scope.taskID == resolved.frame.scope.taskID,
                      opened.scope.kind == .app else { throw AgentEnvironmentError.scopeChanged }
                try checkActive()
                if let cachedWeb, current !== cachedWeb { retired.append(current) }
                current = next
            } catch {
                await next.stop()
                throw error
            }
            return .init(status: .ok, result: "Opened a bound application window.")
        default:
            return try await current.execute(resolved)
        }
    }

    func suspend() async { suspended = true; await current.suspend() }
    func resume() async throws {
        guard !stopped else { throw CancellationError() }
        try await current.resume(); suspended = false
    }
    func stop() async {
        stopped = true
        var environments = retired
        environments.append(current)
        if let cachedWeb { environments.append(cachedWeb) }
        var stoppedIdentities = Set<ObjectIdentifier>()
        for environment in environments {
            let identity = ObjectIdentifier(environment)
            guard stoppedIdentities.insert(identity).inserted else { continue }
            await environment.stop()
        }
        retired.removeAll()
        cachedWeb = nil
        cachedWebScope = nil
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !stopped, !suspended else { throw CancellationError() }
    }
    private func context(_ observation: AgentObservation) -> AgentObservationContext {
        .init(task: observation.task, history: observation.history, budget: observation.budget)
    }

    private func recheckOldScope(_ resolved: AgentResolvedAction) async throws {
        let fresh = try await current.resolve(resolved.action, in: resolved.frame)
        let expected = resolved.frame.scope
        guard fresh.frame.scope.taskID == expected.taskID,
              fresh.frame.scope.kind == expected.kind,
              fresh.frame.scope.identity == expected.identity else {
            throw AgentEnvironmentError.scopeChanged
        }
        try checkActive()
    }

    private func validateReusedWebScope(_ scope: AgentScope, taskID: String) throws {
        guard let expected = cachedWebScope, scope.taskID == taskID,
              scope.kind == .web, scope.identity == expected.identity else {
            throw AgentEnvironmentError.scopeChanged
        }
    }
}
