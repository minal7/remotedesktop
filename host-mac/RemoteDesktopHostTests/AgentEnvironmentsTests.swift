import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentEnvironmentsTests: XCTestCase {
    func testExplicitOpenAppAndOpenURLActionsSwitchBoundEnvironments() async throws {
        let start = EnvironmentFixture(taskID: "task", kind: .app, identity: "start-window",
                                      surface: .app(bundleID: "com.example.editor", title: nil))
        let webURLs = SwitchCapture<String>()
        let appNames = SwitchCapture<String>()
        let webScopes = SwitchCapture<String>()
        let webInstances = SwitchCapture<EnvironmentFixture>()
        let appInstances = SwitchCapture<EnvironmentFixture>()
        let environments = AgentEnvironments(start: start,
            makeWeb: { url in
                webURLs.values.append(url)
                let identity = "web-tab-\(webURLs.values.count)"
                webScopes.values.append(identity)
                let web = EnvironmentFixture(taskID: "task", kind: .web, identity: identity,
                    surface: .web(url: url, title: nil))
                webInstances.values.append(web)
                return web
            },
            makeMac: {
                let app = EnvironmentFixture(taskID: "task", kind: .app, identity: "opened-window",
                    surface: .app(bundleID: "com.example.editor", title: nil))
                appInstances.values.append(app)
                return app
            },
            openApp: { appNames.values.append($0) })

        let appFrame = try await environments.observe(context())
        let firstNavigation = AgentAction.openURL(url: "https://example.test/path")
        _ = try await environments.execute(.init(action: firstNavigation, frame: appFrame, targets: []))
        let webFrame = try await environments.observe(context())
        XCTAssertEqual(webFrame.scope.kind, .web)
        XCTAssertEqual(webFrame.scope.identity, "web-tab-1")
        XCTAssertEqual(webURLs.values, ["https://example.test/path"])

        let launch = AgentAction.openApp(name: "Text Editor")
        _ = try await environments.execute(.init(action: launch, frame: webFrame, targets: []))
        let nextAppFrame = try await environments.observe(context())
        XCTAssertEqual(nextAppFrame.scope.kind, .app)
        XCTAssertEqual(nextAppFrame.scope.identity, "opened-window")
        XCTAssertEqual(appNames.values, ["Text Editor"])

        let secondNavigation = AgentAction.openURL(url: "https://example.test/next")
        _ = try await environments.execute(.init(action: secondNavigation, frame: nextAppFrame, targets: []))
        let finalFrame = try await environments.observe(context())
        XCTAssertEqual(finalFrame.scope.kind, .web)
        XCTAssertEqual(webScopes.values, ["web-tab-1"])
        XCTAssertEqual(webURLs.values, ["https://example.test/path"])
        XCTAssertEqual(webInstances.values[0].executed.map(\.type), ["open_url"])
        XCTAssertEqual(webInstances.values[0].stopCount, 0)
        await environments.stop()
        XCTAssertEqual(start.stopCount, 1)
        XCTAssertEqual(appInstances.values[0].stopCount, 1)
        XCTAssertEqual(webInstances.values[0].stopCount, 1)
    }

    func testSurfaceChangingActionsOnlySwitchFromTheOppositeBoundSurface() async throws {
        let start = EnvironmentFixture(taskID: "task", kind: .web, identity: "existing-tab",
                                      surface: .web(url: "https://example.test/", title: nil))
        let makeWebCalls = SwitchCapture<String>()
        let makeMacCalls = SwitchCapture<Int>()
        let environments = AgentEnvironments(start: start,
            makeWeb: { url in
                makeWebCalls.values.append(url)
                return EnvironmentFixture(taskID: "task", kind: .web, identity: "new-tab",
                    surface: .web(url: url, title: nil))
            },
            makeMac: {
                makeMacCalls.values.append(1)
                return EnvironmentFixture(taskID: "task", kind: .app, identity: "new-window",
                    surface: .app(bundleID: "com.example.editor", title: nil))
            },
            openApp: { _ in })
        let webFrame = try await environments.observe(context())

        let navigate = AgentAction.openURL(url: "https://example.test/next")
        _ = try await environments.execute(.init(action: navigate, frame: webFrame, targets: []))
        XCTAssertEqual(makeWebCalls.values, [])
        XCTAssertEqual(start.executed.map(\.type), ["open_url"])

        let launch = AgentAction.openApp(name: "Text Editor")
        _ = try await environments.execute(.init(action: launch, frame: webFrame, targets: []))
        XCTAssertEqual(makeMacCalls.values, [1])
        let appFrame = try await environments.observe(context())
        let sameSurfaceLaunch = AgentAction.openApp(name: "Another App")
        _ = try await environments.execute(.init(action: sameSurfaceLaunch, frame: appFrame, targets: []))
        XCTAssertEqual(makeMacCalls.values, [1])
        XCTAssertEqual(makeWebCalls.values, [])
    }

    func testInitiallyBoundWebAdapterIsReusedAfterAppSwitchAndStoppedOnce() async throws {
        let start = EnvironmentFixture(taskID: "task", kind: .web, identity: "initial-task-tab",
                                      surface: .web(url: "https://example.test/", title: nil))
        let appInstances = SwitchCapture<EnvironmentFixture>()
        let webFactoryCalls = SwitchCapture<String>()
        let environments = AgentEnvironments(start: start,
            makeWeb: { url in
                webFactoryCalls.values.append(url)
                throw AgentEnvironmentError.unavailable("A cached bound tab should be reused.")
            },
            makeMac: {
                let app = EnvironmentFixture(taskID: "task", kind: .app, identity: "task-window",
                    surface: .app(bundleID: "com.example.editor", title: nil))
                appInstances.values.append(app)
                return app
            },
            openApp: { _ in })

        let webFrame = try await environments.observe(context())
        _ = try await environments.execute(.init(action: .openApp(name: "Editor"), frame: webFrame, targets: []))
        let appFrame = try await environments.observe(context())
        _ = try await environments.execute(.init(action: .openURL(url: "https://example.test/next"),
            frame: appFrame, targets: []))
        let returnedFrame = try await environments.observe(context())

        XCTAssertEqual(returnedFrame.scope.identity, "initial-task-tab")
        XCTAssertEqual(webFactoryCalls.values, [])
        XCTAssertEqual(start.executed.map(\.type), ["open_url"])
        await environments.stop()
        XCTAssertEqual(start.stopCount, 1)
        XCTAssertEqual(appInstances.values[0].stopCount, 1)
    }

    func testSurfaceSwitchRejectsIfOldScopeChangesAtEffectBoundary() async throws {
        let start = EnvironmentFixture(taskID: "task", kind: .app, identity: "start-window",
                                      surface: .app(bundleID: "com.example.editor", title: nil))
        start.scopeOnNextResolve = .init(taskID: "task", kind: .app, identity: "replacement-window")
        let webFactories = SwitchCapture<String>()
        let environments = AgentEnvironments(start: start,
            makeWeb: { url in
                webFactories.values.append(url)
                return EnvironmentFixture(taskID: "task", kind: .web, identity: "tab",
                    surface: .web(url: url, title: nil))
            },
            makeMac: { EnvironmentFixture(taskID: "task", kind: .app, identity: "new-window",
                surface: .app(bundleID: "com.example.editor", title: nil)) },
            openApp: { _ in })

        let frame = try await environments.observe(context())
        do {
            _ = try await environments.execute(.init(action: .openURL(url: "https://example.test/"),
                frame: frame, targets: []))
            XCTFail("A changed bound window must block the surface transition")
        } catch let error as AgentEnvironmentError {
            XCTAssertEqual(error, .scopeChanged)
        }
        XCTAssertEqual(webFactories.values, [])
    }

    func testNewAdapterIsStoppedWhenInitialObservationFails() async throws {
        let start = EnvironmentFixture(taskID: "task", kind: .app, identity: "start-window",
                                      surface: .app(bundleID: "com.example.editor", title: nil))
        let next = EnvironmentFixture(taskID: "task", kind: .web, identity: "new-tab",
                                      surface: .web(url: "https://example.test/", title: nil))
        next.observeError = AgentEnvironmentError.unavailable("test")
        let environments = AgentEnvironments(start: start, makeWeb: { _ in next },
            makeMac: { throw AgentEnvironmentError.unavailable("unused") }, openApp: { _ in })
        let frame = try await environments.observe(context())
        do {
            _ = try await environments.execute(.init(action: .openURL(url: "https://example.test/"),
                frame: frame, targets: []))
            XCTFail("Expected adapter observation failure")
        } catch {}
        XCTAssertEqual(next.stopCount, 1)
    }

    private func context() -> AgentObservationContext {
        AgentObservationContext(task: "A generic task", history: [], budget: .init(step: 0, maxSteps: 40))
    }
}

@MainActor
private final class SwitchCapture<Value> {
    var values: [Value] = []
}

@MainActor
private final class EnvironmentFixture: AgentEnvironment {
    private let taskID: String
    private let kind: AgentScope.Kind
    private let identity: String
    private let surface: AgentSurface
    private(set) var executed: [AgentAction] = []
    private(set) var stopCount = 0
    var scopeOnNextResolve: AgentScope?
    var observeError: Error?

    init(taskID: String, kind: AgentScope.Kind, identity: String, surface: AgentSurface) {
        self.taskID = taskID; self.kind = kind; self.identity = identity; self.surface = surface
    }

    func observe(_ context: AgentObservationContext) async throws -> AgentFrame {
        if let observeError { throw observeError }
        let observation = AgentObservation(task: context.task, surface: surface, screenshot: "", elements: [],
            focus: nil, history: context.history, budget: context.budget)
        return AgentFrame(observation: observation, scope: .init(taskID: taskID, kind: kind, identity: identity))
    }

    func resolve(_ action: AgentAction, in frame: AgentFrame) async throws -> AgentResolvedAction {
        let resolvedFrame: AgentFrame
        if let scope = scopeOnNextResolve {
            scopeOnNextResolve = nil
            resolvedFrame = AgentFrame(observation: frame.observation, scope: scope,
                                       authorityDigest: frame.authorityDigest)
        } else {
            resolvedFrame = frame
        }
        return AgentResolvedAction(action: action, frame: resolvedFrame, targets: [])
    }

    func execute(_ resolved: AgentResolvedAction) async throws -> AgentExecutionResult {
        executed.append(resolved.action)
        return .init(status: .ok, result: "Executed")
    }

    func stop() async { stopCount += 1 }
}
