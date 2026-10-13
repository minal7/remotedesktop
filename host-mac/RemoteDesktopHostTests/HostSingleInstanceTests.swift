import Darwin
import Foundation
import XCTest
@testable import RemoteDesktopHost

final class HostSingleInstanceTests: XCTestCase {
    func testCopiesWithSameBundleIdentityShareOnePerUserLease() throws {
        let directory = try temporaryDirectory()
        var first: HostSingleInstanceLease? = try HostSingleInstance.acquire(
            bundleIdentifier: "com.example.desktop-host",
            lockDirectory: directory)

        XCTAssertNotNil(first)
        XCTAssertNil(
            try HostSingleInstance.acquire(
                bundleIdentifier: "com.example.desktop-host",
                lockDirectory: directory),
            "a second install path with the same bundle ID must not start a second host")

        first = nil
        XCTAssertNotNil(
            try HostSingleInstance.acquire(
                bundleIdentifier: "com.example.desktop-host",
                lockDirectory: directory),
            "closing the old process releases its kernel lock for the replacement")
    }

    func testDifferentBundleIdentitiesCanRunIndependently() throws {
        let directory = try temporaryDirectory()
        let first = try HostSingleInstance.acquire(
            bundleIdentifier: "com.example.desktop-host.debug",
            lockDirectory: directory)
        let second = try HostSingleInstance.acquire(
            bundleIdentifier: "com.example.desktop-host.release",
            lockDirectory: directory)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
    }

    func testRelaunchWaitsUntilTheOldProcessExits() {
        var processChecks = 0
        var waits = 0
        let completed = HostRelaunch.waitForExit(
            123,
            timeout: 1,
            isProcessRunning: { _ in
                processChecks += 1
                return processChecks < 4
            },
            sleep: { _ in waits += 1 })

        XCTAssertTrue(completed)
        XCTAssertEqual(processChecks, 4)
        XCTAssertEqual(waits, 3)
    }

    func testRelaunchWaitFailsClosedAtDeadline() {
        let completed = HostRelaunch.waitForExit(
            123,
            timeout: 0,
            isProcessRunning: { _ in true },
            sleep: { _ in XCTFail("a timed out relaunch must not continue waiting") })

        XCTAssertFalse(completed)
    }

    func testRelaunchCommandLaunchesOwnBundleAfterExitCheck() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return XCTFail("test host must have a bundle identifier")
        }
        let bundleURL = Bundle.main.bundleURL
        var checks = 0
        var launchCount = 0
        let result = HostRelaunch.runIfRequested(
            arguments: ["RemoteDesktopHost", HostRelaunch.command, "123", bundleURL.path],
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            isProcessRunning: { _ in
                checks += 1
                return checks == 1
            },
            sleep: { _ in },
            launch: { requestedURL in
                XCTAssertEqual(requestedURL, bundleURL.resolvingSymlinksInPath().standardizedFileURL)
                XCTAssertEqual(checks, 2, "Launch Services must run only after the old PID exits")
                launchCount += 1
            })

        XCTAssertEqual(result, 0)
        XCTAssertEqual(launchCount, 1)
    }

    func testRelaunchTimeoutDoesNotLaunchReplacement() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return XCTFail("test host must have a bundle identifier")
        }
        let bundleURL = Bundle.main.bundleURL
        var launchCount = 0
        let result = HostRelaunch.runIfRequested(
            arguments: ["RemoteDesktopHost", HostRelaunch.command, "123", bundleURL.path],
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            timeout: 0,
            isProcessRunning: { _ in true },
            sleep: { _ in XCTFail("zero timeout must fail without sleeping") },
            launch: { _ in launchCount += 1 })

        XCTAssertEqual(result, 3)
        XCTAssertEqual(launchCount, 0)
    }

    func testRelaunchRejectsDifferentBundleTarget() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return XCTFail("test host must have a bundle identifier")
        }
        let bundleURL = Bundle.main.bundleURL
        let otherBundleURL = bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Other.app", isDirectory: true)
        var launchCount = 0
        let result = HostRelaunch.runIfRequested(
            arguments: ["RemoteDesktopHost", HostRelaunch.command, "123", otherBundleURL.path],
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            isProcessRunning: { _ in XCTFail("invalid target must be rejected before waiting"); return false },
            sleep: { _ in XCTFail("invalid target must not wait") },
            launch: { _ in launchCount += 1 })

        XCTAssertEqual(result, 2)
        XCTAssertEqual(launchCount, 0)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-instance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
