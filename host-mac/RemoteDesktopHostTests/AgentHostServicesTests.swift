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

    func testAppRegistryDiscoversFromInjectedSystemRootAndKeepsInvalidNamesSafe() throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let coreServices = root.appendingPathComponent("System/Library/CoreServices", isDirectory: true)
        let adjacentApplications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: coreServices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: adjacentApplications, withIntermediateDirectories: true)
        let primary = try makeApp(name: "Fixture Utility", bundleID: "org.example.fixture.utility", under: coreServices)
        _ = try makeApp(name: "Duplicate Utility", bundleID: "org.example.duplicate.one", under: coreServices)
        _ = try makeApp(name: "Duplicate Utility", bundleID: "org.example.duplicate.two", under: adjacentApplications)
        try makeApp(name: "Incomplete Utility", bundleID: nil, under: coreServices)

        let registry = AgentAppRegistry(searchRoots: [coreServices, adjacentApplications])

        XCTAssertEqual(try registry.resolve("fixture utility").bundleID, "org.example.fixture.utility")
        XCTAssertEqual(try registry.resolve("ORG.EXAMPLE.FIXTURE.UTILITY").url, primary)
        XCTAssertThrowsError(try registry.resolve("duplicate utility")) { error in
            guard let failure = error as? AgentAppRegistry.Failure,
                  case .ambiguous = failure else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try registry.resolve("incomplete utility")) { error in
            guard let failure = error as? AgentAppRegistry.Failure,
                  case .notFound = failure else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testDefaultAppSearchRootsIncludeSystemComponentBundles() {
        XCTAssertTrue(AgentAppRegistry.defaultSearchRoots.contains {
            $0.standardizedFileURL.path == "/System/Library/CoreServices"
        })
        XCTAssertTrue(AgentAppRegistry.defaultSearchRoots.contains {
            $0.standardizedFileURL.path == "/System/Cryptexes/App/System/Applications"
        })
    }

    func testCryptexSystemApplicationRootDiscoversGenericDisplayNames() throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("System/Cryptexes/App/System/Applications",
                                                        isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let appURL = try makeApp(name: "Fixture Browser", bundleID: "org.example.fixture.browser",
                                 under: applications)

        let registry = AgentAppRegistry(searchRoots: [applications])

        XCTAssertEqual(try registry.resolve("fixture browser"),
                       AgentRegisteredApp(bundleID: "org.example.fixture.browser",
                                          url: appURL.standardizedFileURL))
        XCTAssertEqual(try registry.resolve("ORG.EXAMPLE.FIXTURE.BROWSER").url,
                       appURL.standardizedFileURL)
    }

    func testAppRegistryDoesNotFollowArbitrarySymlinkBundles() throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let searchRoot = root.appendingPathComponent("Applications", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: searchRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let appURL = try makeApp(name: "Linked Utility", bundleID: "org.example.linked",
                                 under: outside)
        try FileManager.default.createSymbolicLink(
            at: searchRoot.appendingPathComponent("Linked Utility.app"), withDestinationURL: appURL)

        let registry = AgentAppRegistry(searchRoots: [searchRoot])

        XCTAssertThrowsError(try registry.resolve("Linked Utility")) { error in
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
        return try makeApp(name: name, bundleID: bundleID, under: root)
    }

    @discardableResult
    private func makeApp(name: String, bundleID: String?, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(name + ".app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info: [String: Any] = ["CFBundleName": name, "CFBundleDisplayName": name,
                                   "CFBundlePackageType": "APPL"]
        info["CFBundleIdentifier"] = bundleID
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
