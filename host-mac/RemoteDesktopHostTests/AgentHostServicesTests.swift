import AppKit
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentHostServicesTests: XCTestCase {
    func testAppRegistryUsesExactNormalizedNameOrBundleIDAndRejectsAmbiguity() throws {
        let firstURL = try makeApp(name: "Calendar Fixture", bundleID: "org.example.calendar")
        let secondURL = try makeApp(name: "Calendar Fixture", bundleID: "org.example.other")
        let distinctURL = try makeApp(name: "Notes Fixture", bundleID: "org.example.notes")
        let registry = AgentAppRegistry(records: [
            .init(displayName: "Calendar Fixture", bundleID: "org.example.calendar", url: firstURL),
            .init(displayName: "Calendar Fixture", bundleID: "org.example.other", url: secondURL),
            .init(displayName: "Notes Fixture", bundleID: "org.example.notes", url: distinctURL),
        ])

        XCTAssertEqual(try registry.resolve("  ORG.EXAMPLE.NOTES ").bundleID, "org.example.notes")
        XCTAssertEqual(try registry.resolve("notes fixture").url, distinctURL)
        XCTAssertThrowsError(try registry.resolve("calendar fixture")) { error in
            guard let failure = error as? AgentAppRegistry.Failure,
                  case .ambiguous = failure else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try registry.resolve("not installed")) { error in
            guard let failure = error as? AgentAppRegistry.Failure,
                  case .notFound = failure else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testAppOpenUsesResolvedHostRecordAndPolicyDeniesUnknownApps() async throws {
        let appURL = try makeApp(name: "Generic Utility", bundleID: "org.example.utility")
        var opened: URL?
        let registry = AgentAppRegistry(records: [.init(displayName: "Generic Utility",
            bundleID: "org.example.utility", url: appURL)], openHandler: { opened = $0 })
        let app = try registry.resolve("generic utility")
        try await registry.open(app)
        XCTAssertEqual(opened, appURL)

        let policy = HostAgentAllowPolicy(registry: registry)
        let scope = AgentScope(taskID: "fixture", kind: .app, identity: "org.example.current")
        XCTAssertEqual(policy.decision(for: .openApp(name: "unknown"), in: scope),
                       .denied("The requested app is not installed or could not be resolved."))
        XCTAssertEqual(policy.resolvedTrustIdentity(for: .openApp(name: "GENERIC UTILITY"), in: scope),
                       AgentTrustIdentity(kind: .app, identity: "org.example.utility"))

        let forged = AgentRegisteredApp(bundleID: "org.example.other", url: appURL)
        do { try await registry.open(forged); XCTFail("A mismatched app record was opened") }
        catch { XCTAssertTrue(error is AgentAppRegistry.Failure) }
    }

    func testAllowPolicyRestrictsURLsAndReturnsCanonicalOrigin() {
        let registry = AgentAppRegistry(records: [])
        let policy = HostAgentAllowPolicy(registry: registry)
        let scope = AgentScope(taskID: "fixture", kind: .web, identity: "surface")
        for url in ["https://example.test/path", "http://localhost:8080/path",
                    "http://127.0.0.2/", "http://[::1]:9000/"] {
            XCTAssertEqual(policy.decision(for: .openURL(url: url), in: scope), .allowed, url)
        }
        for url in ["http://example.test/", "file:///tmp/item", "javascript:alert(1)",
                    "https://user:secret@example.test/", "https://example.test:0/"] {
            XCTAssertTrue(isDenied(policy.decision(for: .openURL(url: url), in: scope)), url)
            XCTAssertNil(policy.resolvedTrustIdentity(for: .openURL(url: url), in: scope), url)
        }
        XCTAssertEqual(policy.resolvedTrustIdentity(for: .openURL(url: "HTTPS://Example.Test:443/a"), in: scope),
                       AgentTrustIdentity(kind: .web, identity: "https://example.test"))
        XCTAssertEqual(policy.resolvedTrustIdentity(for: .openURL(url: "http://127.0.0.1:80/a"), in: scope),
                       AgentTrustIdentity(kind: .web, identity: "http://127.0.0.1"))
    }

    func testPersistentTrustIsScopedToExactOriginOrBundleAndSurvivesReopen() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistentAgentTrustStore(directory: directory)
        XCTAssertFalse(try store.isTrusted(kind: .web, identity: "https://example.test"))
        try store.markTrusted(kind: .web, identity: "https://example.test")
        try store.markTrusted(kind: .app, identity: "org.example.utility")

        let reopened = try PersistentAgentTrustStore(directory: directory)
        XCTAssertTrue(try reopened.isTrusted(kind: .web, identity: "https://example.test"))
        XCTAssertTrue(try reopened.isTrusted(kind: .app, identity: "org.example.utility"))
        XCTAssertFalse(try reopened.isTrusted(kind: .web, identity: "https://other.test"))
        let storedContents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(storedContents.contains("example.test"))
        XCTAssertFalse(storedContents.contains("org.example.utility"))
    }

    private func makeApp(name: String, bundleID: String) throws -> URL {
        let root = try makePrivateDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(name + ".app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name,
                                   "CFBundleDisplayName": name, "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Info.plist"))
        return url.deletingLastPathComponent()
    }

    private func makePrivateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func isDenied(_ decision: AgentAccessDecision) -> Bool {
        if case .denied = decision { return true }
        return false
    }
}
