import Darwin
import Foundation
import XCTest
@testable import MemoryStoreKit

private enum ForgetTestError: Error, CustomStringConvertible {
    case injectedKeyDeletionFailure
    var description: String { "synthetic-private-key-deletion-error" }
}

private final class ForgetTestKeychain: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ExactKeychainItem: Data] = [:]
    private var failDeletes = 0
    private(set) var deleteCalls = 0

    init(failDeletes: Int = 0) { self.failDeletes = failDeletes }

    func add(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard items[item] == nil else { throw KeychainBoundaryError.duplicateItem }
        items[item] = data
    }

    func copy(_ item: ExactKeychainItem) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = items[item] else { throw KeychainBoundaryError.missingItem }
        return value
    }

    func delete(_ item: ExactKeychainItem) throws {
        lock.lock(); defer { lock.unlock() }
        deleteCalls += 1
        if failDeletes > 0 {
            failDeletes -= 1
            throw ForgetTestError.injectedKeyDeletionFailure
        }
        guard items.removeValue(forKey: item) != nil else { throw KeychainBoundaryError.missingItem }
    }
}

private struct ForgetTestRandom: MemoryKeyRandomSource {
    func bytes(count: Int) throws -> Data { Data(repeating: 0x6d, count: count) }
}

private final class ForgetTestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func set(_ value: String) { lock.lock(); stored = value; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class ForgetTestWriterReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: OwnerMemoryWriter?
    func set(_ writer: OwnerMemoryWriter) { lock.lock(); stored = writer; lock.unlock() }
    func get() -> OwnerMemoryWriter? { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class ForgetTestWriterError: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: OwnerMemoryWriterError?
    func set(_ error: OwnerMemoryWriterError?) { lock.lock(); stored = error; lock.unlock() }
    func get() -> OwnerMemoryWriterError? { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class ForgetTestAuthBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func authorize() -> Bool {
        lock.lock()
        calls += 1
        let shouldBlock = calls == 1
        lock.unlock()
        if shouldBlock {
            entered.signal()
            _ = release.wait(timeout: .now() + 4)
        }
        return true
    }
}

final class PersonalMemoryForgetTests: XCTestCase {
    private let owner = OwnerMemoryContext(ownerID: "synthetic-owner", sessionID: "synthetic-session")
    private let task = OwnerMemoryContext(ownerID: "synthetic-owner", sessionID: "synthetic-session",
                                          taskID: "synthetic-task")

    private func open(_ client: ForgetTestKeychain, testName: String,
                      authorize: @escaping OwnerMemoryAuthorizer = { _ in true }) throws -> (PersonalMemoryService, URL) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalMemoryForget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        let service = try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: client, random: ForgetTestRandom(), namespace: .testing("forget-\(testName)"),
            authorize: authorize, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        return (service, root)
    }

    private func candidate(_ text: String) -> OwnerMemoryCandidate {
        OwnerMemoryCandidate(kind: .fact, text: text, origin: .model,
                             sourceReference: "fixture-message", sourceSpan: "fixture-span")
    }

    private func assertForgotten(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(error as? OwnerMemoryWriterError, .forgotten,
                      "post-Forget writer access must return a fixed forgotten error",
                      file: file, line: line)
    }

    func testForgetPurgesStagedProposalAndPermanentlyFencesExistingWriter() throws {
        let (service, root) = try open(ForgetTestKeychain(), testName: "success")
        let proposal = try service.writer.stageProposal(candidate: candidate("synthetic candidate"),
                                                        context: task)

        try service.forgetAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("memory.sqlite").path))
        XCTAssertThrowsError(try service.writer.confirmProposal(proposalID: proposal.proposalID,
            commandID: "confirm-after-forget", context: task)) { self.assertForgotten($0) }
        XCTAssertThrowsError(try service.writer.stageProposal(candidate: candidate("new candidate"),
            context: task)) { self.assertForgotten($0) }
        XCTAssertThrowsError(try service.writer.remember(kind: .fact, text: "new write",
            commandID: "write-after-forget", context: owner)) { self.assertForgotten($0) }
        XCTAssertThrowsError(try service.writer.list(context: owner)) { self.assertForgotten($0) }
        XCTAssertThrowsError(try service.writer.search("synthetic", context: owner)) { self.assertForgotten($0) }
    }

    func testForgetFailureKeepsWriterFencedAndRetryCompletesKeyAndFileErasure() throws {
        let keychain = ForgetTestKeychain(failDeletes: 1)
        let (service, root) = try open(keychain, testName: "retry")
        let proposal = try service.writer.stageProposal(candidate: candidate("retry candidate"), context: task)
        let database = root.appendingPathComponent("memory.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))

        XCTAssertThrowsError(try service.forgetAll()) { error in
            XCTAssertTrue(String(describing: error).localizedCaseInsensitiveContains("memory erasure"))
            XCTAssertFalse(String(reflecting: error).contains("synthetic-private-key-deletion-error"))
        }
        XCTAssertThrowsError(try service.writer.confirmProposal(proposalID: proposal.proposalID,
            commandID: "retry-confirm", context: task)) { self.assertForgotten($0) }
        XCTAssertThrowsError(try service.writer.list(context: owner)) { self.assertForgotten($0) }

        try service.forgetAll()

        XCTAssertEqual(keychain.deleteCalls, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertThrowsError(try service.writer.remember(kind: .fact, text: "still fenced",
            commandID: "retry-write", context: owner)) { self.assertForgotten($0) }
    }

    func testForgetWaitsForAdmittedWriteAndRejectsOperationsAtFence() throws {
        let authBarrier = ForgetTestAuthBarrier()
        let authorize: OwnerMemoryAuthorizer = { _ in authBarrier.authorize() }
        let ownerContext = owner
        let (service, _) = try open(ForgetTestKeychain(), testName: "concurrent", authorize: authorize)
        let writeOutcome = ForgetTestWriterError()
        let writeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                _ = try service.writer.remember(kind: .fact, text: "in-flight fixture write",
                    commandID: "in-flight", context: ownerContext)
                writeOutcome.set(nil)
            } catch { writeOutcome.set(error as? OwnerMemoryWriterError) }
            writeFinished.signal()
        }
        XCTAssertEqual(authBarrier.entered.wait(timeout: .now() + 2), .success)

        let forgetFinished = DispatchSemaphore(value: 0)
        let forgetOutcome = ForgetTestResult()
        DispatchQueue.global().async {
            do { try service.forgetAll(); forgetOutcome.set("completed") }
            catch { forgetOutcome.set(String(reflecting: error)) }
            forgetFinished.signal()
        }

        let deadline = DispatchTime.now() + .seconds(2)
        var fenceObserved = false
        while DispatchTime.now() < deadline {
            do { _ = try service.writer.list(context: ownerContext) }
            catch let error as OwnerMemoryWriterError where error == .forgotten {
                fenceObserved = true
                break
            } catch { }
            Thread.sleep(forTimeInterval: 0.002)
        }
        XCTAssertTrue(fenceObserved, "Forget must fence new work while draining admitted work")
        XCTAssertEqual(forgetFinished.wait(timeout: .now()), .timedOut,
                       "Forget must wait for an already-admitted operation")
        authBarrier.release.signal()
        XCTAssertEqual(writeFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(forgetFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(writeOutcome.get(), .forgotten)
        XCTAssertEqual(forgetOutcome.get(), "completed")
    }

    func testSameThreadForgetFromAuthorizationCallbackFailsWithoutDeadlockOrFence() throws {
        let writerReference = ForgetTestWriterReference()
        let callbackResult = ForgetTestWriterError()
        let (service, _) = try open(ForgetTestKeychain(), testName: "reentrant") { _ in
            do {
                try writerReference.get()?.beginForget()
                callbackResult.set(nil)
            } catch {
                callbackResult.set(error as? OwnerMemoryWriterError)
            }
            return true
        }
        writerReference.set(service.writer)

        _ = try service.writer.remember(kind: .fact, text: "owner callback fixture",
            commandID: "reentrant-callback", context: owner)

        XCTAssertEqual(callbackResult.get(), .forgetReentrant)
        XCTAssertEqual(try service.writer.list(context: owner).count, 1,
                       "the rejected callback did not begin erasure")
        try service.forgetAll()
        XCTAssertThrowsError(try service.writer.list(context: owner)) { self.assertForgotten($0) }
    }
}
