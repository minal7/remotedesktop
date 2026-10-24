import Foundation
import XCTest
@testable import MemoryStoreKit

private final class ForgetAuthorizationKeychain: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExactKeychainItem: Data] = [:]
    private var failedDeletes = 0
    var beforeDelete: (() -> Void)?

    init(failedDeletes: Int = 0) { self.failedDeletes = failedDeletes }
    func add(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard values[item] == nil else { throw KeychainBoundaryError.duplicateItem }
        values[item] = data
    }
    func copy(_ item: ExactKeychainItem) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[item] else { throw KeychainBoundaryError.missingItem }
        return value
    }
    func delete(_ item: ExactKeychainItem) throws {
        beforeDelete?()
        lock.lock(); defer { lock.unlock() }
        if failedDeletes > 0 { failedDeletes -= 1; throw KeychainBoundaryError.accessDenied }
        guard values.removeValue(forKey: item) != nil else { throw KeychainBoundaryError.missingItem }
    }
}

private struct ForgetAuthorizationRandom: MemoryKeyRandomSource {
    func bytes(count: Int) throws -> Data { Data(repeating: 0x47, count: count) }
}

private final class ForgetAuthorizationVerifier: VaultFillTrustedApprovalVerifier, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var blocks = false
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func verifyOwnerApproval(_ receipt: VaultFillApprovalReceipt,
                             for challenge: VaultFillApprovalChallenge) throws { try verify() }
    func verifyFreshPhoneBiometric(_ receipt: VaultFillApprovalReceipt,
                                   for challenge: VaultFillApprovalChallenge) throws { try verify() }
    private func verify() throws {
        lock.lock(); calls += 1; let shouldBlock = blocks; lock.unlock()
        if shouldBlock { entered.signal(); _ = release.wait(timeout: .now() + 5) }
    }
}

private final class ForgetAuthorizationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var permit: VaultFillPermit?
    private var error: Error?
    func set(permit: VaultFillPermit?, error: Error?) { lock.lock(); self.permit = permit; self.error = error; lock.unlock() }
    func get() -> (VaultFillPermit?, Error?) { lock.lock(); defer { lock.unlock() }; return (permit, error) }
}

private final class ForgetAuthorizationRuntimeAction: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    func set(_ action: @escaping () -> Void) { lock.lock(); self.action = action; lock.unlock() }
    func runOnce() {
        lock.lock(); let current = action; action = nil; lock.unlock()
        current?()
    }
}

final class VaultForgetAuthorizationTests: XCTestCase {
    private func makeDraft(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> VaultFillApprovalDraft {
        let authority = VaultFillOwnerTaskAuthority(ownerID: "forget-owner", sessionID: "forget-session",
            taskID: "forget-task", revision: 3, intent: .ownerTaskExplicitlyRequestedFill)
        let target = VaultFillWebTargetInput(reference: "forget-ref", navigationGeneration: 1,
            frameGeneration: 2, topLevelOrigin: "https://checkout.example",
            frameOrigin: "https://checkout.example", autocomplete: "cc-number", inputType: .text,
            purpose: .typedFormField, contentEditable: false, visible: true, editable: true, secure: false)
        return try XCTUnwrap(VaultFillEligibility.assess(authority: authority, target: .web(target),
            request: VaultFillRequest(handle: VaultItemID(), itemKind: .paymentCard, field: .cardNumber),
            now: now, monotonicNow: { 1_000 }).draft)
    }

    private func open(_ keychain: ForgetAuthorizationKeychain, _ label: String,
                      authorize: @escaping OwnerMemoryAuthorizer = { _ in true }) throws -> PersonalMemoryService {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultForgetAuthorization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("store", isDirectory: true)
        return try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: keychain, random: ForgetAuthorizationRandom(), namespace: .testing("forget-auth-\(label)"),
            authorize: authorize, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
    }

    private func lifecycle(_ service: PersonalMemoryService, draft: VaultFillApprovalDraft,
                           verifier: ForgetAuthorizationVerifier) throws -> VaultFillAuthorizationLifecycle {
        try service.makeVaultFillAuthorizationLifecycle(draft: draft,
            currentRuntime: { VaultFillRuntimeSnapshot(binding: VaultFillCurrentBinding(draft: draft), status: .active) },
            verifier: verifier, now: { draft.createdAtWall.addingTimeInterval(1) },
            monotonicNow: { draft.createdAtMonotonic + 1 })
    }

    func testForgetInvalidatesExistingPermitBeforeFailedKeychainErase() throws {
        let keychain = ForgetAuthorizationKeychain(failedDeletes: 1)
        let service = try open(keychain, "failed-erase")
        let item = VaultItemID()
        try service.storeVaultSecret(VaultSecretValue("4242424242424242"), for: item, field: .cardNumber)
        let draft = try makeDraft()
        let verifier = ForgetAuthorizationVerifier()
        let lifecycle = try lifecycle(service, draft: draft, verifier: verifier)
        let permit = try lifecycle.authorize(VaultFillApprovalReceipt(challenge: VaultFillApprovalChallenge(draft: draft), proof: Data([1])))
        let deleteAttempt = ForgetAuthorizationResult()
        keychain.beforeDelete = {
            do { try permit.consume(); deleteAttempt.set(permit: nil, error: nil) }
            catch { deleteAttempt.set(permit: nil, error: error) }
        }

        XCTAssertThrowsError(try service.forgetAll())
        XCTAssertEqual(deleteAttempt.get().1 as? VaultFillAuthorizationError,
                       .invalidated(.memoryForgotten), "permit is fenced before the first Keychain delete")
        XCTAssertThrowsError(try permit.consume()) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.memoryForgotten))
        }
        XCTAssertThrowsError(try lifecycle.authorize(VaultFillApprovalReceipt(
            challenge: VaultFillApprovalChallenge(draft: draft), proof: Data([2])))) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.memoryForgotten))
        }
    }

    func testForgetFencesPendingVerificationEvenWhenVerifierReturnsLate() throws {
        let service = try open(ForgetAuthorizationKeychain(), "pending")
        let draft = try makeDraft()
        let verifier = ForgetAuthorizationVerifier(); verifier.blocks = true
        let lifecycle = try lifecycle(service, draft: draft, verifier: verifier)
        let challenge = VaultFillApprovalChallenge(draft: draft)
        let result = ForgetAuthorizationResult()
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do { result.set(permit: try lifecycle.authorize(VaultFillApprovalReceipt(challenge: challenge, proof: Data([1]))), error: nil) }
            catch { result.set(permit: nil, error: error) }
            completed.signal()
        }
        let verifierStarted = verifier.entered.wait(timeout: .now() + 2) == .success
        defer {
            verifier.release.signal()
            _ = completed.wait(timeout: .now() + 2)
        }
        XCTAssertTrue(verifierStarted)
        if verifierStarted { try service.forgetAll() }
        verifier.release.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertNil(result.get().0)
        XCTAssertEqual(result.get().1 as? VaultFillAuthorizationError, .invalidated(.memoryForgotten))
    }

    func testForgetRejectsNewServiceLifecycleAndRewrappedChallenge() throws {
        let service = try open(ForgetAuthorizationKeychain(), "rewrap")
        let draft = try makeDraft()
        let verifier = ForgetAuthorizationVerifier()
        let first = try lifecycle(service, draft: draft, verifier: verifier)
        let second = try lifecycle(service, draft: draft, verifier: verifier)
        let challenge = VaultFillApprovalChallenge(draft: draft)
        try service.forgetAll()

        XCTAssertThrowsError(try first.authorize(VaultFillApprovalReceipt(challenge: challenge, proof: Data([1])))) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.memoryForgotten))
        }
        XCTAssertThrowsError(try second.authorize(VaultFillApprovalReceipt(challenge: VaultFillApprovalChallenge(draft: draft), proof: Data([2])))) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.memoryForgotten))
        }
        XCTAssertThrowsError(try lifecycle(service, draft: try makeDraft(), verifier: verifier)) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.memoryForgotten))
        }
        XCTAssertEqual(verifier.callCount, 0)
    }

    func testRejectedReentrantForgetDoesNotRevokeFillAuthorization() throws {
        let service = try open(ForgetAuthorizationKeychain(), "reentrant")
        let serviceBox = ForgetAuthorizationServiceBox(); serviceBox.service = service
        let item = VaultItemID()
        try service.storeVaultSecret(VaultSecretValue("4242424242424242"), for: item, field: .cardNumber)
        let callbackErrors = ForgetAuthorizationResult()
        try service.withVaultSecret(for: item, field: .cardNumber) { _ in
            do { try serviceBox.service?.forgetAll(); callbackErrors.set(permit: nil, error: nil) }
            catch { callbackErrors.set(permit: nil, error: error) }
        }
        XCTAssertEqual(callbackErrors.get().1 as? MemoryFactoryError, .memoryErasureFailed)
        let draft = try makeDraft()
        let verifier = ForgetAuthorizationVerifier()
        let lifecycle = try lifecycle(service, draft: draft, verifier: verifier)
        let permit = try lifecycle.authorize(VaultFillApprovalReceipt(challenge: VaultFillApprovalChallenge(draft: draft), proof: Data([3])))
        XCTAssertNoThrow(try permit.consume())
    }

    func testForgetThroughSecondServiceInvalidatesFirstServicesPermit() throws {
        let keychain = ForgetAuthorizationKeychain()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultForgetAuthorization-shared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("shared-store", isDirectory: true)
        func openService() throws -> PersonalMemoryService {
            try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
                client: keychain, random: ForgetAuthorizationRandom(), namespace: .testing("forget-auth-shared"),
                authorize: { _ in true }, isTaskActive: { _, _ in true },
                policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        }

        let firstService = try openService()
        let forgettingService = try openService()
        let draft = try makeDraft()
        let verifier = ForgetAuthorizationVerifier()
        let lifecycle = try lifecycle(firstService, draft: draft, verifier: verifier)
        let permit = try lifecycle.authorize(VaultFillApprovalReceipt(
            challenge: VaultFillApprovalChallenge(draft: draft), proof: Data([4])))

        try forgettingService.forgetAll()

        XCTAssertThrowsError(try permit.consume()) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.memoryForgotten))
        }
    }

    func testClosingServiceInvalidatesItsIssuedPermit() throws {
        let service = try open(ForgetAuthorizationKeychain(), "closed-service")
        let draft = try makeDraft()
        let verifier = ForgetAuthorizationVerifier()
        let lifecycle = try lifecycle(service, draft: draft, verifier: verifier)
        let permit = try lifecycle.authorize(VaultFillApprovalReceipt(
            challenge: VaultFillApprovalChallenge(draft: draft), proof: Data([5])))

        try service.close()

        XCTAssertThrowsError(try permit.consume()) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.serviceClosed))
        }
    }

    func testRuntimeCallbackClosingServiceDuringConsumeCannotPassFence() throws {
        let service = try open(ForgetAuthorizationKeychain(), "runtime-close")
        let draft = try makeDraft()
        let verifier = ForgetAuthorizationVerifier()
        let action = ForgetAuthorizationRuntimeAction()
        let snapshot = VaultFillRuntimeSnapshot(binding: VaultFillCurrentBinding(draft: draft), status: .active)
        let lifecycle = try service.makeVaultFillAuthorizationLifecycle(draft: draft,
            currentRuntime: { action.runOnce(); return snapshot }, verifier: verifier,
            now: { draft.createdAtWall.addingTimeInterval(1) },
            monotonicNow: { draft.createdAtMonotonic + 1 })
        let permit = try lifecycle.authorize(VaultFillApprovalReceipt(
            challenge: VaultFillApprovalChallenge(draft: draft), proof: Data([6])))
        action.set { try? service.close() }

        XCTAssertThrowsError(try permit.consume()) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.serviceClosed))
        }
    }

    func testRuntimeCallbackForgettingServiceDuringConsumeCannotPassFence() throws {
        let service = try open(ForgetAuthorizationKeychain(), "runtime-forget")
        let draft = try makeDraft()
        let verifier = ForgetAuthorizationVerifier()
        let action = ForgetAuthorizationRuntimeAction()
        let forgetResult = ForgetAuthorizationResult()
        let snapshot = VaultFillRuntimeSnapshot(binding: VaultFillCurrentBinding(draft: draft), status: .active)
        let lifecycle = try service.makeVaultFillAuthorizationLifecycle(draft: draft,
            currentRuntime: { action.runOnce(); return snapshot }, verifier: verifier,
            now: { draft.createdAtWall.addingTimeInterval(1) },
            monotonicNow: { draft.createdAtMonotonic + 1 })
        let permit = try lifecycle.authorize(VaultFillApprovalReceipt(
            challenge: VaultFillApprovalChallenge(draft: draft), proof: Data([7])))
        action.set {
            do { try service.forgetAll(); forgetResult.set(permit: nil, error: nil) }
            catch { forgetResult.set(permit: nil, error: error) }
        }

        XCTAssertThrowsError(try permit.consume()) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.memoryForgotten))
        }
        XCTAssertNil(forgetResult.get().1, "reentrant Forget should complete from the runtime callback")
    }
}

private final class ForgetAuthorizationServiceBox: @unchecked Sendable {
    var service: PersonalMemoryService?
}
