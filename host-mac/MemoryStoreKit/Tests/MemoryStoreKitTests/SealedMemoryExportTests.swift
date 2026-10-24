import CryptoKit
import Foundation
import XCTest
@testable import MemoryStoreKit

private final class ExportKeyAdapter: KeychainClient, MemoryKeyRandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExactKeychainItem: Data] = [:]
    private var reads = 0
    private var seed: UInt8 = 0
    func add(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard values[item] == nil else { throw KeychainBoundaryError.duplicateItem }
        values[item] = data
    }
    func copy(_ item: ExactKeychainItem) throws -> Data {
        lock.lock(); defer { lock.unlock() }; reads += 1
        guard let data = values[item] else { throw KeychainBoundaryError.missingItem }
        return data
    }
    func delete(_ item: ExactKeychainItem) throws {
        lock.lock(); defer { lock.unlock() }
        guard values.removeValue(forKey: item) != nil else { throw KeychainBoundaryError.missingItem }
    }
    func replace(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard values[item] != nil else { throw KeychainBoundaryError.missingItem }
        values[item] = data
    }
    func bytes(count: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }; seed &+= 1
        return Data(repeating: seed, count: count)
    }
    func readCount() -> Int { lock.lock(); defer { lock.unlock() }; return reads }
}

private final class ExportControls: @unchecked Sendable {
    private let lock = NSLock()
    private let policyWaiter = DispatchSemaphore(value: 0)
    private let policyRelease = DispatchSemaphore(value: 0)
    private var isAllowed = true
    private var currentPolicy = OwnerMemoryPolicy(featureEnabled: true)
    private var policyCalls = 0
    private var blockedCall: Int?
    func allow(_ value: Bool) { lock.lock(); isAllowed = value; lock.unlock() }
    func policy(_ value: OwnerMemoryPolicy) { lock.lock(); currentPolicy = value; lock.unlock() }
    func allows() -> Bool { lock.lock(); defer { lock.unlock() }; return isAllowed }
    func snapshot() -> OwnerMemoryPolicy {
        lock.lock()
        policyCalls += 1
        let call = policyCalls
        let value = currentPolicy
        let shouldBlock = call == blockedCall
        lock.unlock()
        if shouldBlock {
            policyWaiter.signal()
            _ = policyRelease.wait(timeout: .now() + 5)
        }
        return value
    }
    func blockPolicyCall(_ call: Int) { lock.lock(); policyCalls = 0; blockedCall = call; lock.unlock() }
    func waitForBlockedPolicy() -> Bool { policyWaiter.wait(timeout: .now() + 3) == .success }
    func releasePolicy() { policyRelease.signal() }
}

private final class ExportResults: @unchecked Sendable {
    private let lock = NSLock()
    private var exported = false
    private var forgotten = false
    func markExported() { lock.lock(); exported = true; lock.unlock() }
    func markForgotten() { lock.lock(); forgotten = true; lock.unlock() }
    func values() -> (Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (exported, forgotten) }
}

final class SealedMemoryExportTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let parent: URL
        let namespace: KeychainNamespace
        let keys: ExportKeyAdapter
        let controls: ExportControls
        let service: PersonalMemoryService
        let workspaceRoot: Bool
        let context = OwnerMemoryContext(ownerID: "fixture-owner", sessionID: "fixture-session")
        func cleanup() { try? service.close(); try? FileManager.default.removeItem(at: parent) }
    }

    private func fixture(workspaceRoot: Bool = false) throws -> Fixture {
        let parent: URL
        if workspaceRoot {
            let workspace = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            parent = workspace.appendingPathComponent("build/eval/report-prep/sealed-memory-export/fixtures",
                isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        } else {
            parent = FileManager.default.temporaryDirectory
                .appendingPathComponent("SealedMemoryExport-\(UUID().uuidString)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let keys = ExportKeyAdapter(), controls = ExportControls()
        let namespace = KeychainNamespace.testing(UUID().uuidString)
        let binding = try XCTUnwrap(MemoryStoreFactory.captureBindingForTesting(enabled: true,
            root: root, client: keys, namespace: namespace))
        let service = try XCTUnwrap(MemoryStoreFactory.openBoundGenerationForTesting(enabled: true,
            binding: binding, client: keys, random: keys, authorize: { [controls] context in
                controls.allows() && context.ownerID == "fixture-owner" && context.sessionID == "fixture-session"
            }, isTaskActive: { _, _ in true }, policy: { [controls] in controls.snapshot() }))
        return Fixture(root: root, parent: parent, namespace: namespace, keys: keys,
                       controls: controls, service: service, workspaceRoot: workspaceRoot)
    }

    private func remember(_ f: Fixture, _ text: String, kind: OwnerRememberKind = .fact) throws -> String {
        try f.service.writer.remember(kind: kind, text: text, commandID: UUID().uuidString,
                                      context: f.context).recordID
    }

    func testUnauthorizedAndReadRestrictionsFailBeforeKeychainReads() throws {
        let f = try fixture(); defer { f.cleanup() }
        _ = try remember(f, "fixture detail")
        let reads = f.keys.readCount()
        f.controls.allow(false)
        let key = try SealedMemoryExportKey(SymmetricKey(data: Data(repeating: 7, count: 32)))
        XCTAssertThrowsError(try f.service.exportSealedMemory(context: f.context, key: key)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .unauthorized)
        }
        XCTAssertEqual(f.keys.readCount(), reads)
        f.controls.allow(true)
        f.controls.policy(OwnerMemoryPolicy(featureEnabled: true, incognito: true))
        XCTAssertThrowsError(try f.service.exportSealedMemory(context: f.context, key: key)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .incognito)
        }
        XCTAssertEqual(f.keys.readCount(), reads)
        f.controls.policy(OwnerMemoryPolicy(featureEnabled: false))
        XCTAssertThrowsError(try f.service.exportSealedMemory(context: f.context, key: key)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .disabled)
        }
        XCTAssertEqual(f.keys.readCount(), reads)
        f.controls.policy(OwnerMemoryPolicy(featureEnabled: true, noMemory: true))
        XCTAssertThrowsError(try f.service.exportSealedMemory(context: f.context, key: key)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .noMemory)
        }
        XCTAssertEqual(f.keys.readCount(), reads)
    }

    func testPauseLearningDoesNotBlockReadingAndEnvelopeIsAuthenticatedAndAllowlisted() throws {
        let f = try fixture(); defer { f.cleanup() }
        let binding = try XCTUnwrap(f.service.generationBinding)
        if !f.workspaceRoot {
            XCTAssertNotEqual(binding.generation.root, f.service.storageRoot,
                "the temporary root exercises /tmp versus its physical path")
        }
        XCTAssertEqual(binding.generation.root.standardizedFileURL.path,
                       f.service.storageRoot.standardizedFileURL.path)
        let profileID = try remember(f, "fictional preference: blue", kind: .profile)
        _ = try remember(f, "fictional fact: Harbor City", kind: .fact)
        let rawStore = try XCTUnwrap(MemoryStore.open(enabled: true,
            databaseURL: f.root.appendingPathComponent("memory.sqlite"),
            keyProvider: KeychainMemoryKeyProvider(client: f.keys, random: f.keys, namespace: f.namespace)))
        try rawStore.setActive(false, id: profileID)
        try rawStore.upsert(MemoryRecord(id: "fictional-episode", kind: .episode,
            body: "episode must never export", source: .ownerConfirmed, observedAt: 99,
            provenance: MemoryProvenance(sourceSpan: "private lineage must never export")))
        try rawStore.registerVaultItem(UUID())
        try rawStore.close()
        f.controls.policy(OwnerMemoryPolicy(featureEnabled: true, pauseLearning: true))
        let rawKey = Data(repeating: 0x6a, count: 32)
        let symmetricKey = SymmetricKey(data: rawKey)
        let key = try SealedMemoryExportKey(symmetricKey)
        let first = try f.service.exportSealedMemory(context: f.context, key: key)
        let second = try f.service.exportSealedMemory(context: f.context, key: key)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertEqual(first.formatVersion, 1)
        let payload = try decrypt(first, key: symmetricKey)
        XCTAssertEqual(payload["format"] as? String, "personal-memory-export-v1")
        let records = try XCTUnwrap(payload["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.flatMap(\.keys)), ["id", "kind", "body", "source", "observedAt", "active", "confidence"])
        XCTAssertTrue(records.allSatisfy { ["profile", "fact"].contains($0["kind"] as? String ?? "") })
        let inactiveProfile = try XCTUnwrap(records.first { $0["id"] as? String == profileID })
        XCTAssertEqual(inactiveProfile["active"] as? Bool, false)
        XCTAssertFalse(records.contains { ($0["body"] as? String ?? "").contains("episode") })
        XCTAssertThrowsError(try decrypt(first, key: SymmetricKey(data: Data(repeating: 0x33, count: 32))))
        var altered = first.ciphertext
        altered[altered.startIndex] ^= 1
        let damaged = SealedMemoryExportEnvelope(nonce: first.nonce, ciphertext: altered,
                                                  authenticationTag: first.authenticationTag)
        XCTAssertThrowsError(try decrypt(damaged, key: symmetricKey))
        let changedVersion = SealedMemoryExportEnvelope(formatVersion: 2, nonce: first.nonce,
            ciphertext: first.ciphertext, authenticationTag: first.authenticationTag)
        XCTAssertThrowsError(try decrypt(changedVersion, key: symmetricKey))
    }

    func testPhysicalWorkspaceRootBindingAlsoExports() throws {
        let f = try fixture(workspaceRoot: true); defer { f.cleanup() }
        _ = try remember(f, "fictional physical-root record")
        let key = try SealedMemoryExportKey(SymmetricKey(data: Data(repeating: 3, count: 32)))
        XCTAssertNoThrow(try f.service.exportSealedMemory(context: f.context, key: key))
    }

    func testInvalidKeyBoundsOverflowStaleBindingAndForgetAreRejected() throws {
        let f = try fixture(); defer { f.cleanup() }
        _ = try remember(f, "fictional 1")
        _ = try remember(f, "fictional 2")
        let key = try SealedMemoryExportKey(SymmetricKey(data: Data(repeating: 1, count: 32)))
        XCTAssertThrowsError(try SealedMemoryExportKey(SymmetricKey(data: Data(repeating: 1, count: 16))))
        XCTAssertThrowsError(try f.service.exportSealedMemory(context: f.context, key: key, maximumRecords: 1))
        XCTAssertThrowsError(try f.service.exportSealedMemory(context: f.context, key: key, maximumBytes: 1))
        try f.service.forgetAll()
        XCTAssertThrowsError(try f.service.exportSealedMemory(context: f.context, key: key))
    }

    func testCapturedOldGenerationCannotExportAfterExplicitGenerationAdvance() throws {
        let f = try fixture(); defer { f.cleanup() }
        _ = try remember(f, "fictional old generation")
        let oldBinding = try XCTUnwrap(f.service.generationBinding)
        try f.service.forgetAll()
        let replacement = try XCTUnwrap(MemoryStoreFactory.initializeAfterForgetBindingForTesting(
            enabled: true, expectedBinding: oldBinding, commandID: UUID(), client: f.keys, random: f.keys))
        XCTAssertNotEqual(replacement.reference, oldBinding.reference)
        let key = try SealedMemoryExportKey(SymmetricKey(data: Data(repeating: 2, count: 32)))
        XCTAssertThrowsError(try f.service.exportSealedMemory(context: f.context, key: key)) { error in
            XCTAssertEqual(error as? SealedMemoryExportError, .staleBinding)
        }
    }

    func testForgetDuringSealingWaitsForExportAndSuppressesLateEnvelope() throws {
        let f = try fixture(); defer { f.cleanup() }
        _ = try remember(f, "fictional concurrent export")
        let key = try SealedMemoryExportKey(SymmetricKey(data: Data(repeating: 9, count: 32)))
        f.controls.blockPolicyCall(3)
        let exportDone = DispatchSemaphore(value: 0)
        let forgetDone = DispatchSemaphore(value: 0)
        let results = ExportResults()
        DispatchQueue.global().async {
            defer { exportDone.signal() }
            do {
                _ = try f.service.exportSealedMemory(context: f.context, key: key)
                results.markExported()
            } catch { }
        }
        XCTAssertTrue(f.controls.waitForBlockedPolicy(), "export should reach post-query revalidation")
        DispatchQueue.global().async {
            defer { forgetDone.signal() }
            do { try f.service.forgetAll(); results.markForgotten() }
            catch { }
        }
        let fenceDeadline = Date().addingTimeInterval(3)
        var forgetFenceVisible = false
        while Date() < fenceDeadline {
            do { try f.service.store.requireActive() }
            catch { forgetFenceVisible = true; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(forgetFenceVisible, "Forget must publish its fence while export is paused")
        f.controls.releasePolicy()
        XCTAssertEqual(exportDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(forgetDone.wait(timeout: .now() + 5), .success)
        let (exported, forgotten) = results.values()
        XCTAssertFalse(exported, "a sealed payload must not escape after Forget wins")
        XCTAssertTrue(forgotten)
    }

    func testCancellationDuringPostQueryRevalidationSuppressesEnvelope() async throws {
        let f = try fixture(); defer { f.cleanup() }
        _ = try remember(f, "fictional cancelled export")
        let context = f.context, service = f.service, controls = f.controls
        let key = try SealedMemoryExportKey(SymmetricKey(data: Data(repeating: 4, count: 32)))
        controls.blockPolicyCall(3)
        let task = Task.detached {
            try service.exportSealedMemory(context: context, key: key)
        }
        XCTAssertTrue(controls.waitForBlockedPolicy(), "export should reach post-query revalidation")
        task.cancel()
        controls.releasePolicy()
        do {
            _ = try await task.value
            XCTFail("cancelled export must not produce an envelope")
        } catch is CancellationError { }
        catch { XCTFail("expected cancellation, got \(error)") }
    }

    func testConcurrentRememberDoesNotMixIntoCompletedSnapshot() async throws {
        let f = try fixture(); defer { f.cleanup() }
        _ = try remember(f, "fictional before snapshot")
        let binding = try XCTUnwrap(f.service.generationBinding)
        let peer = try XCTUnwrap(MemoryStoreFactory.openBoundGenerationForTesting(enabled: true,
            binding: binding, client: f.keys, random: f.keys, authorize: { [controls = f.controls] context in
                controls.allows() && context.ownerID == "fixture-owner"
                    && context.sessionID == "fixture-session"
            }, isTaskActive: { _, _ in true }, policy: { [controls = f.controls] in controls.snapshot() }))
        defer { try? peer.close() }
        let context = f.context, service = f.service, controls = f.controls
        let rawKey = SymmetricKey(data: Data(repeating: 0x2a, count: 32))
        let key = try SealedMemoryExportKey(rawKey)
        controls.blockPolicyCall(3)
        let task = Task.detached {
            try service.exportSealedMemory(context: context, key: key)
        }
        XCTAssertTrue(controls.waitForBlockedPolicy(), "export should finish its one-statement query")
        _ = try peer.writer.remember(kind: .fact, text: "fictional after snapshot",
                                     commandID: UUID().uuidString, context: context)
        controls.releasePolicy()
        let payload = try decrypt(try await task.value, key: rawKey)
        let records = try XCTUnwrap(payload["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?["body"] as? String, "fictional before snapshot")
    }

    private func decrypt(_ envelope: SealedMemoryExportEnvelope, key: SymmetricKey) throws -> [String: Any] {
        let nonce = try AES.GCM.Nonce(data: envelope.nonce)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: envelope.ciphertext,
                                        tag: envelope.authenticationTag)
        let aad = SealedMemoryExportCodec.authenticatedFormat(version: envelope.formatVersion)
        let clear = try AES.GCM.open(box, using: key, authenticating: aad)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: clear) as? [String: Any])
    }
}
