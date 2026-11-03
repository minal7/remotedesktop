import XCTest
import AppKit
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseDefaultBrowserTargetTests: XCTestCase {
    private typealias Target = ComputerUseDefaultBrowserTarget
    private typealias Resolver = ComputerUseDefaultBrowserTargetResolver

    func testTargetUsesDynamicallyResolvedHTTPSHandlerAndPinsObservedWindow() async throws {
        for (identifier, pid) in [("com.apple.Safari", pid_t(401)), ("com.google.Chrome", pid_t(402))] {
            let handler = try makeHandler(identifier)
            let identity = appIdentity(identifier: identifier, path: handler.bundleURL.path, pid: pid)
            let window = makeWindow(pid: pid, hash: CFHashCode(pid))
            var launchedURL: URL?
            let resolver = Resolver(resolveHandler: { _ in handler },
                launch: { url, selectedHandler in
                    launchedURL = url
                    XCTAssertEqual(selectedHandler, handler)
                    return identity
                }, focusedWindow: { _ in window })
            let url = URL(string: "https://drive.google.com/drive/my-drive")!
            let target = try await resolver.open(taskID: "task", url: url)
            XCTAssertEqual(launchedURL, url)
            XCTAssertEqual(target.handler, handler)
            XCTAssertEqual(target.application, identity)
            XCTAssertEqual(target.window, window)
            XCTAssertNoThrow(try target.validate(taskID: "task", currentApplication: identity, currentWindow: window))
        }
    }

    func testMissingHTTPSHandlerFailsClosed() async {
        let resolver = Resolver(resolveHandler: { _ in nil }, launch: { _, _ in nil }, focusedWindow: { _ in nil })
        do {
            _ = try await resolver.open(taskID: "task", url: URL(string: "https://drive.google.com")!)
            XCTFail("A missing default handler must not fall through to another browser")
        } catch { XCTAssertEqual(error as? Target.Failure, .noDefaultHandler) }
    }

    func testInvalidURLsAndPrecancelledTaskNeverLaunch() async {
        let handler = try! makeHandler("org.example.Browser")
        var launchCount = 0
        let resolver = Resolver(resolveHandler: { _ in handler }, launch: { _, _ in
            launchCount += 1
            return nil
        }, focusedWindow: { _ in nil })
        for raw in ["http://example.com", "file:///tmp/file", "https://user:pass@example.com"] {
            do {
                _ = try await resolver.open(taskID: "task", url: URL(string: raw)!)
                XCTFail("Only credential-free HTTPS URLs are eligible")
            } catch { XCTAssertEqual(error as? Target.Failure, .invalidHTTPSURL) }
        }
        let cancelled = Task { try await resolver.open(taskID: "task", url: URL(string: "https://example.com")!) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled resolution must not dispatch the opener")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(launchCount, 0)
    }

    func testDifferentBundleIDOrCanonicalPathIsRejected() async throws {
        let handler = try makeHandler("com.google.Chrome")
        for mismatch in [
            appIdentity(identifier: "com.apple.Safari", path: "/Applications/Safari.app", pid: 9),
            appIdentity(identifier: handler.bundleIdentifier, path: "/Applications/Other Chrome.app", pid: 10),
        ] {
            let resolver = Resolver(resolveHandler: { _ in handler }, launch: { _, _ in mismatch }, focusedWindow: { _ in nil })
            do {
                _ = try await resolver.open(taskID: "task", url: URL(string: "https://example.com")!)
                XCTFail("The running process must match both the resolved handler ID and canonical path")
            } catch { XCTAssertEqual(error as? Target.Failure, .handlerIdentityMismatch) }
        }
    }

    func testMissingRunningCodeProofIsRejected() async throws {
        let handler = try makeHandler("com.google.Chrome")
        let unverified = ComputerUseApplicationIdentity(bundleIdentifier: handler.bundleIdentifier, processIdentifier: 11, launchGeneration: 1)
        let resolver = Resolver(resolveHandler: { _ in handler }, launch: { _, _ in unverified }, focusedWindow: { _ in nil })
        do {
            _ = try await resolver.open(taskID: "task", url: URL(string: "https://example.com")!)
            XCTFail("A PID without signed-code identity cannot be a browser target")
        } catch { XCTAssertEqual(error as? Target.Failure, .applicationNotCodeVerified) }
    }

    func testMissingWindowAndStaleTaskWindowOrReusedPIDAreRejected() async throws {
        let handler = try makeHandler("org.example.Browser")
        let identity = appIdentity(identifier: handler.bundleIdentifier, path: handler.bundleURL.path, pid: 77)
        let window = makeWindow(pid: 77, hash: 5)
        let missing = Resolver(resolveHandler: { _ in handler }, launch: { _, _ in identity }, focusedWindow: { _ in nil })
        do {
            _ = try await missing.open(taskID: "task", url: URL(string: "https://example.com")!)
            XCTFail("No unique observed window must not produce a target")
        } catch { XCTAssertEqual(error as? Target.Failure, .noUniqueFocusedWindow) }

        let resolver = Resolver(resolveHandler: { _ in handler }, launch: { _, _ in identity }, focusedWindow: { _ in window })
        let target = try await resolver.open(taskID: "task", url: URL(string: "https://example.com")!)
        XCTAssertThrowsError(try target.validate(taskID: "other", currentApplication: identity, currentWindow: window))
        XCTAssertThrowsError(try target.validate(taskID: "task", currentApplication: identity, currentWindow: makeWindow(pid: 77, hash: 6)))
        XCTAssertThrowsError(try target.validate(taskID: "task",
            currentApplication: appIdentity(identifier: handler.bundleIdentifier, path: handler.bundleURL.path, pid: 77, generation: 2),
            currentWindow: window))
    }

    func testLiveDefaultHTTPSHandlerResolutionIsOptInAndReadOnly() throws {
        guard ProcessInfo.processInfo.environment["COMPUTER_USE_DEFAULT_BROWSER_LIVE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Set COMPUTER_USE_DEFAULT_BROWSER_LIVE_ACCEPTANCE=1 to inspect the HTTPS handler")
        }
        let handler = try XCTUnwrap(Target.currentDefaultHTTPSHandler(), "Launch Services must resolve an HTTPS handler")
        XCTAssertTrue(handler.bundleURL.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: handler.bundleURL.path))
        XCTAssertEqual(Bundle(url: handler.bundleURL)?.bundleIdentifier, handler.bundleIdentifier)
    }

    func testLiveForegroundIdentityIsOptInAndSkippedUnlessDefaultHandlerIsFrontmost() throws {
        guard ProcessInfo.processInfo.environment["COMPUTER_USE_DEFAULT_BROWSER_LIVE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Set COMPUTER_USE_DEFAULT_BROWSER_LIVE_ACCEPTANCE=1 to inspect foreground app/window identity")
        }
        let handler = try XCTUnwrap(Target.currentDefaultHTTPSHandler(), "Launch Services must resolve an HTTPS handler")
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier == handler.bundleIdentifier else {
            throw XCTSkip("The current foreground app is not the default HTTPS handler")
        }
        let (_, identity, window) = try XCTUnwrap(Target.currentDefaultHandlerForegroundWindow())
        XCTAssertEqual(handler.bundleIdentifier, identity.bundleIdentifier)
        XCTAssertEqual(window.applicationProcessIdentifier, identity.processIdentifier)
        XCTAssertNotNil(identity.codeIdentity)
    }

    private func makeHandler(_ identifier: String) throws -> Target.Handler {
        let appURL = URL(fileURLWithPath: "/offscreen-fixtures/\(UUID().uuidString).app")
        return Target.Handler(bundleURL: appURL, bundleIdentifier: identifier)
    }

    private func makeWindow(pid: pid_t, hash: CFHashCode) -> ComputerUseFrontmostWindowCaptureIdentity {
        ComputerUseFrontmostWindowCaptureIdentity(applicationProcessIdentifier: pid,
            accessibilityWindowHash: hash, bounds: CGRect(x: 4, y: 5, width: 800, height: 600))
    }

    private func appIdentity(identifier: String, path: String, pid: pid_t, generation: UInt64 = 1) -> ComputerUseApplicationIdentity {
        let code = ComputerUseApplicationCodeIdentity(authority: .runningCode,
            bundleIdentifier: identifier, canonicalBundlePath: URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path,
            canonicalExecutablePath: "\(path)/Contents/MacOS/Browser", designatedRequirement: "test",
            teamIdentifier: "TEST", platformIdentifier: nil)
        return try! XCTUnwrap(ComputerUseApplicationIdentity(bundleIdentifier: identifier,
            processIdentifier: pid, launchGeneration: generation, codeIdentity: code))
    }
}
