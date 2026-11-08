import Foundation
import XCTest
@testable import MemoryStoreKit

private final class MutableVaultFillRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var state: VaultFillRuntimeSnapshot
    private var time: Date
    private var monotonic: TimeInterval

    init(state: VaultFillRuntimeSnapshot, now: Date, monotonic: TimeInterval = 1_000) {
        self.state = state; time = now; self.monotonic = monotonic
    }
    func snapshot() -> VaultFillRuntimeSnapshot { lock.lock(); defer { lock.unlock() }; return state }
    func set(_ value: VaultFillRuntimeSnapshot) { lock.lock(); defer { lock.unlock() }; state = value }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return time }
    func setNow(_ value: Date) { lock.lock(); defer { lock.unlock() }; time = value }
    func monotonicNow() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return monotonic }
    func setMonotonic(_ value: TimeInterval) { lock.lock(); defer { lock.unlock() }; monotonic = value }
}

private final class FakeTrustedVaultFillVerifier: VaultFillTrustedApprovalVerifier, @unchecked Sendable {
    private let lock = NSLock()
    private var ordinary = 0
    private var biometric = 0
    var rejectVerification = false
    var duringVerification: (() -> Void)?
    var verificationEntered: DispatchSemaphore?
    var verificationRelease: DispatchSemaphore?

    var ordinaryCalls: Int { lock.lock(); defer { lock.unlock() }; return ordinary }
    var biometricCalls: Int { lock.lock(); defer { lock.unlock() }; return biometric }

    func verifyOwnerApproval(_ receipt: VaultFillApprovalReceipt,
                             for challenge: VaultFillApprovalChallenge) throws {
        try record(biometric: false)
    }

    func verifyFreshPhoneBiometric(_ receipt: VaultFillApprovalReceipt,
                                   for challenge: VaultFillApprovalChallenge) throws {
        try record(biometric: true)
    }

    private func record(biometric requiresBiometric: Bool) throws {
        lock.lock()
        if requiresBiometric { biometric += 1 } else { ordinary += 1 }
        let reject = rejectVerification
        let callback = duringVerification
        let entered = verificationEntered
        let release = verificationRelease
        lock.unlock()
        callback?()
        entered?.signal()
        release?.wait()
        if reject { throw VaultFillAuthorizationError.verificationFailed }
    }
}

private final class ConcurrentPermitResults: @unchecked Sendable {
    private let lock = NSLock()
    private var authorizationCount = 0
    private var consumeCount = 0
    private var permit: VaultFillPermit?

    func save(_ value: VaultFillPermit) { lock.lock(); defer { lock.unlock() }; authorizationCount += 1; permit = value }
    func recordConsume() { lock.lock(); defer { lock.unlock() }; consumeCount += 1 }
    func snapshot() -> (Int, Int, VaultFillPermit?) {
        lock.lock(); defer { lock.unlock() }; return (authorizationCount, consumeCount, permit)
    }
}

final class VaultFillAuthorizationTests: XCTestCase {
    private let ownerID = "owner-1"
    private let sessionID = "session-2"
    private let taskID = "task-3"

    private static func waitForSignal(_ semaphore: DispatchSemaphore) {
        semaphore.wait()
    }

    private func draft(field: VaultSecretField = .cardNumber,
                       itemKind: VaultFillItemKind = .paymentCard,
                       now: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> VaultFillApprovalDraft {
        let authority = VaultFillOwnerTaskAuthority(ownerID: ownerID, sessionID: sessionID,
            taskID: taskID, revision: 7, intent: .ownerTaskExplicitlyRequestedFill)
        let token: String
        switch field {
        case .cardNumber: token = "cc-number"
        case .cardExpiryMonth: token = "cc-exp-month"
        case .cardExpiryYear: token = "cc-exp-year"
        case .cardholderName: token = "cc-name"
        case .addressLine1: token = "address-line1"
        case .addressLine2: token = "address-line2"
        case .addressCity: token = "address-level2"
        case .addressRegion: token = "address-level1"
        case .addressPostalCode: token = "postal-code"
        case .addressCountry: token = "country-name"
        case .phoneNumber: token = "tel"
        case .membershipNumber, .identityNumber, .identityName, .identityExpiry:
            throw VaultFillDenialReason.unsupportedField
        }
        let web = VaultFillWebTargetInput(reference: "ref-4", navigationGeneration: 11,
            frameGeneration: 12, topLevelOrigin: "https://merchant.example:8443",
            frameOrigin: "https://merchant.example:8443", autocomplete: token,
            inputType: field == .phoneNumber ? .tel : .text, purpose: .typedFormField, contentEditable: false,
            visible: true, editable: true, secure: false)
        return try XCTUnwrap(VaultFillEligibility.assess(authority: authority, target: .web(web),
            request: VaultFillRequest(handle: VaultItemID(uuid: UUID(uuidString:
                "01234567-89AB-CDEF-0123-456789ABCDEF")!), itemKind: itemKind, field: field),
            now: now, monotonicNow: { 1_000 }).draft)
    }

    private func makeLifecycle(draft: VaultFillApprovalDraft,
                               verifier: FakeTrustedVaultFillVerifier,
                               runtime: MutableVaultFillRuntime? = nil) ->
        (VaultFillAuthorizationLifecycle, VaultFillApprovalChallenge, MutableVaultFillRuntime) {
        let challenge = VaultFillApprovalChallenge(draft: draft)
        let runtime = runtime ?? MutableVaultFillRuntime(
            state: VaultFillRuntimeSnapshot(binding: VaultFillCurrentBinding(draft: draft), status: .active),
            now: draft.createdAtWall.addingTimeInterval(10), monotonic: draft.createdAtMonotonic + 10)
        let lifecycle = VaultFillAuthorizationLifecycle(challenge: challenge,
            currentRuntime: { runtime.snapshot() }, verifier: verifier, now: { runtime.now() },
            monotonicNow: { runtime.monotonicNow() })
        return (lifecycle, challenge, runtime)
    }

    func testFreshPhoneBiometricCreatesOneShotValueFreePermit() throws {
        let verifier = FakeTrustedVaultFillVerifier()
        let (lifecycle, challenge, _) = makeLifecycle(draft: try draft(), verifier: verifier)
        let receipt = VaultFillApprovalReceipt(challenge: challenge, proof: Data([0x42]))
        let permit = try lifecycle.authorize(receipt)
        XCTAssertEqual(verifier.biometricCalls, 1)
        XCTAssertEqual(verifier.ordinaryCalls, 0)
        XCTAssertEqual(String(describing: permit), "<vault-fill-permit>")
        XCTAssertEqual(String(reflecting: receipt), "<vault-fill-approval-receipt>")
        XCTAssertNoThrow(try permit.consume())
        XCTAssertThrowsError(try permit.consume()) { XCTAssertEqual($0 as? VaultFillAuthorizationError, .permitAlreadyConsumed) }
        XCTAssertThrowsError(try lifecycle.authorize(receipt)) { XCTAssertEqual($0 as? VaultFillAuthorizationError, .challengeAlreadyUsed) }
    }

    func testEveryPaymentDraftRequiresFreshBiometricAndReceiptCannotCrossChallenges() throws {
        let verifier = FakeTrustedVaultFillVerifier()
        let first = makeLifecycle(draft: try draft(), verifier: verifier)
        let receipt = VaultFillApprovalReceipt(challenge: first.1, proof: Data([0x10]))
        _ = try first.0.authorize(receipt)

        let second = makeLifecycle(draft: try draft(), verifier: verifier)
        XCTAssertThrowsError(try second.0.authorize(receipt)) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .receiptMismatch)
        }
        _ = try second.0.authorize(VaultFillApprovalReceipt(challenge: second.1, proof: Data([0x11])))
        XCTAssertEqual(verifier.biometricCalls, 2)
        XCTAssertEqual(verifier.ordinaryCalls, 0)
    }

    func testNonPaymentUsesOwnerApprovalVerifierWithoutBiometricShortcut() throws {
        let verifier = FakeTrustedVaultFillVerifier()
        let addressDraft = try draft(field: .addressPostalCode, itemKind: .address)
        let (lifecycle, challenge, _) = makeLifecycle(draft: addressDraft, verifier: verifier)
        _ = try lifecycle.authorize(VaultFillApprovalReceipt(challenge: challenge, proof: Data([0x21])))
        XCTAssertEqual(verifier.ordinaryCalls, 1)
        XCTAssertEqual(verifier.biometricCalls, 0)
    }

    func testReceiptMustMatchEveryApprovalBindingField() throws {
        let draft = try draft()
        let mutations: [(String, (inout VaultFillCurrentBinding) -> Void)] = [
            ("owner", { $0.ownerID = "other-owner" }), ("session", { $0.sessionID = "other-session" }),
            ("task", { $0.taskID = "other-task" }), ("revision", { $0.revision += 1 }),
            ("target reference", { $0.targetReference = "other-ref" }),
            ("navigation", { $0.navigationGeneration += 1 }), ("frame", { $0.frameGeneration += 1 }),
            ("origin", { $0.targetIdentity = .web(VaultFillCanonicalOrigin(serialized: "https://other.example")) }),
            ("handle", { $0.handleID = VaultItemID() }), ("field", { $0.field = .cardExpiryMonth })
        ]
        for (name, mutate) in mutations {
            let verifier = FakeTrustedVaultFillVerifier()
            let (lifecycle, challenge, _) = makeLifecycle(draft: draft, verifier: verifier)
            var binding = challenge.binding.current
            mutate(&binding)
            let receipt = VaultFillApprovalReceipt(binding: VaultFillApprovalBinding(
                current: binding, approvalID: challenge.binding.approvalID, nonce: challenge.binding.nonce),
                proof: Data([0x31]))
            XCTAssertThrowsError(try lifecycle.authorize(receipt), name) {
                XCTAssertEqual($0 as? VaultFillAuthorizationError, .receiptMismatch, name)
            }
            XCTAssertEqual(verifier.biometricCalls, 0, "unmatched receipt must be rejected before verification")
        }

        let verifier = FakeTrustedVaultFillVerifier()
        let (lifecycle, challenge, _) = makeLifecycle(draft: draft, verifier: verifier)
        let wrongApproval = VaultFillApprovalReceipt(binding: VaultFillApprovalBinding(
            current: challenge.binding.current, approvalID: UUID(), nonce: challenge.binding.nonce), proof: Data([1]))
        XCTAssertThrowsError(try lifecycle.authorize(wrongApproval)) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .receiptMismatch)
        }
        let wrongNonce = VaultFillApprovalReceipt(binding: VaultFillApprovalBinding(
            current: challenge.binding.current, approvalID: challenge.binding.approvalID, nonce: UUID()), proof: Data([1]))
        XCTAssertThrowsError(try lifecycle.authorize(wrongNonce)) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .receiptMismatch)
        }
    }

    func testCurrentTargetOrTaskChangePreventsAuthorization() throws {
        let changes: [(String, (inout VaultFillCurrentBinding) -> Void)] = [
            ("owner", { $0.ownerID = "changed-owner" }), ("session", { $0.sessionID = "changed-session" }),
            ("task", { $0.taskID = "changed-task" }),
            ("target", { $0.targetReference = "changed" }), ("frame", { $0.frameGeneration += 1 }),
            ("navigation", { $0.navigationGeneration += 1 }), ("origin", {
                $0.targetIdentity = .web(VaultFillCanonicalOrigin(serialized: "https://other.example"))
            }), ("field", { $0.field = .cardExpiryMonth }), ("handle", { $0.handleID = VaultItemID() }),
            ("revision", { $0.revision += 1 })
        ]
        for (name, mutate) in changes {
            let draft = try draft()
            let verifier = FakeTrustedVaultFillVerifier()
            var binding = VaultFillCurrentBinding(draft: draft)
            mutate(&binding)
            let runtime = MutableVaultFillRuntime(state: VaultFillRuntimeSnapshot(binding: binding, status: .active),
                now: draft.createdAtWall.addingTimeInterval(10), monotonic: draft.createdAtMonotonic + 10)
            let (lifecycle, challenge, _) = makeLifecycle(draft: draft, verifier: verifier, runtime: runtime)
            XCTAssertThrowsError(try lifecycle.authorize(VaultFillApprovalReceipt(challenge: challenge, proof: Data([1]))), name) {
                XCTAssertEqual($0 as? VaultFillAuthorizationError, .bindingChanged, name)
            }
            XCTAssertEqual(verifier.biometricCalls, 0)
        }
    }

    func testExpiredAndRevokedRuntimeCannotApprove() throws {
        let inactiveStatuses: [VaultFillRuntimeStatus] = [.revoked, .stopped, .takenOver, .denied, .disconnected]
        for status in inactiveStatuses {
            let draft = try draft()
            let verifier = FakeTrustedVaultFillVerifier()
            let runtime = MutableVaultFillRuntime(state: VaultFillRuntimeSnapshot(
                binding: VaultFillCurrentBinding(draft: draft), status: status),
                now: draft.createdAtWall.addingTimeInterval(10), monotonic: draft.createdAtMonotonic + 10)
            let (lifecycle, challenge, _) = makeLifecycle(draft: draft, verifier: verifier, runtime: runtime)
            XCTAssertThrowsError(try lifecycle.authorize(VaultFillApprovalReceipt(challenge: challenge, proof: Data([1])))) {
                XCTAssertEqual($0 as? VaultFillAuthorizationError, .inactiveTask)
            }
            XCTAssertEqual(verifier.biometricCalls, 0)
        }

        let verifier = FakeTrustedVaultFillVerifier()
        let expiredDraft = try draft(now: Date(timeIntervalSince1970: 1_800_000_000))
        let runtime = MutableVaultFillRuntime(state: VaultFillRuntimeSnapshot(
            binding: VaultFillCurrentBinding(draft: expiredDraft), status: .active),
            now: Date(timeIntervalSince1970: 1_800_000_031))
        let (lifecycle, challenge, _) = makeLifecycle(draft: expiredDraft, verifier: verifier, runtime: runtime)
        XCTAssertThrowsError(try lifecycle.authorize(VaultFillApprovalReceipt(challenge: challenge, proof: Data([1])))) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .expired)
        }
        XCTAssertEqual(verifier.biometricCalls, 0)
    }

    func testWallClockRollbackBeforeFirstAuthorizationCannotExtendChallenge() throws {
        let verifier = FakeTrustedVaultFillVerifier()
        let (lifecycle, challenge, runtime) = makeLifecycle(draft: try draft(), verifier: verifier)
        runtime.setNow(Date(timeIntervalSince1970: -1))
        XCTAssertThrowsError(try lifecycle.authorize(
            VaultFillApprovalReceipt(challenge: challenge, proof: Data([1]))),
            "a backward wall-clock jump before receipt handling must fail closed")
        XCTAssertEqual(verifier.biometricCalls, 0)
    }

    func testExpiredPermitCannotBeUsedAfterWallClockRollsBack() throws {
        let verifier = FakeTrustedVaultFillVerifier()
        let (lifecycle, challenge, runtime) = makeLifecycle(draft: try draft(), verifier: verifier)
        let permit = try lifecycle.authorize(VaultFillApprovalReceipt(challenge: challenge, proof: Data([1])))
        runtime.setNow(Date(timeIntervalSince1970: challenge.expiresAt.timeIntervalSince1970 + 1))
        XCTAssertThrowsError(try permit.consume())
        runtime.setNow(Date(timeIntervalSince1970: challenge.expiresAt.timeIntervalSince1970 - 1))
        XCTAssertThrowsError(try permit.consume(), "wall-clock rollback must not revive an expired permit")
    }

    func testWallClockRollbackAfterLifecycleCreationIsRejectedBeforeVerification() throws {
        let verifier = FakeTrustedVaultFillVerifier()
        let (lifecycle, challenge, runtime) = makeLifecycle(draft: try draft(), verifier: verifier)
        runtime.setNow(Date(timeIntervalSince1970: 1_800_000_009))
        XCTAssertThrowsError(try lifecycle.authorize(
            VaultFillApprovalReceipt(challenge: challenge, proof: Data([1])))) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidClock)
        }
        XCTAssertEqual(verifier.biometricCalls, 0)
    }

    func testMonotonicExpiryCannotBeUndoneByWallClockRollback() throws {
        let verifier = FakeTrustedVaultFillVerifier()
        let (lifecycle, challenge, runtime) = makeLifecycle(draft: try draft(), verifier: verifier)
        let permit = try lifecycle.authorize(VaultFillApprovalReceipt(challenge: challenge, proof: Data([1])))
        runtime.setMonotonic(1_031)
        runtime.setNow(Date(timeIntervalSince1970: challenge.expiresAt.timeIntervalSince1970 - 1))
        XCTAssertThrowsError(try permit.consume()) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.taskRevoked))
        }
        runtime.setMonotonic(1_032)
        XCTAssertThrowsError(try permit.consume()) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.taskRevoked))
        }
    }

    func testInvalidMonotonicSamplesFailClosed() throws {
        for invalid in [-1.0, .nan, .infinity] {
            let verifier = FakeTrustedVaultFillVerifier()
            let challenge = VaultFillApprovalChallenge(draft: try draft())
            let runtime = MutableVaultFillRuntime(
                state: VaultFillRuntimeSnapshot(binding: challenge.binding.current, status: .active),
                now: Date(timeIntervalSince1970: 1_800_000_010), monotonic: invalid)
            let lifecycle = VaultFillAuthorizationLifecycle(challenge: challenge,
                currentRuntime: { runtime.snapshot() }, verifier: verifier,
                now: { runtime.now() }, monotonicNow: { runtime.monotonicNow() })
            XCTAssertThrowsError(try lifecycle.authorize(VaultFillApprovalReceipt(challenge: challenge, proof: Data([1])))) {
                XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidClock)
            }
            XCTAssertEqual(verifier.biometricCalls, 0)
        }

        let verifier = FakeTrustedVaultFillVerifier()
        let (lifecycle, challenge, runtime) = makeLifecycle(draft: try draft(), verifier: verifier)
        runtime.setMonotonic(999)
        XCTAssertThrowsError(try lifecycle.authorize(VaultFillApprovalReceipt(challenge: challenge, proof: Data([1])))) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidClock)
        }
    }

    func testInvalidCreationWallClockSampleFailsClosed() throws {
        let draft = try draft()
        let challenge = VaultFillApprovalChallenge(draft: draft)
        let runtime = MutableVaultFillRuntime(
            state: VaultFillRuntimeSnapshot(binding: VaultFillCurrentBinding(draft: draft), status: .active),
            now: draft.createdAtWall.addingTimeInterval(-1), monotonic: draft.createdAtMonotonic + 1)
        let verifier = FakeTrustedVaultFillVerifier()
        let lifecycle = VaultFillAuthorizationLifecycle(challenge: challenge,
            currentRuntime: { runtime.snapshot() }, verifier: verifier,
            now: { runtime.now() }, monotonicNow: { runtime.monotonicNow() })
        XCTAssertThrowsError(try lifecycle.authorize(VaultFillApprovalReceipt(challenge: challenge, proof: Data([1])))) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidClock)
        }
        XCTAssertEqual(verifier.biometricCalls, 0)
    }

    func testRewrappingOldDraftCannotResetItsMonotonicLifetime() throws {
        let verifier = FakeTrustedVaultFillVerifier()
        let draft = try draft()
        let challenge = VaultFillApprovalChallenge(draft: draft)
        let runtime = MutableVaultFillRuntime(
            state: VaultFillRuntimeSnapshot(binding: VaultFillCurrentBinding(draft: draft), status: .active),
            now: draft.createdAtWall.addingTimeInterval(1), monotonic: draft.createdAtMonotonic + 31)
        let lifecycle = VaultFillAuthorizationLifecycle(challenge: challenge,
            currentRuntime: { runtime.snapshot() }, verifier: verifier,
            now: { runtime.now() }, monotonicNow: { runtime.monotonicNow() })
        XCTAssertThrowsError(try lifecycle.authorize(VaultFillApprovalReceipt(challenge: challenge, proof: Data([1])))) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .expired)
        }
        XCTAssertEqual(verifier.biometricCalls, 0)
    }

    func testRewrappingDraftCannotResetSingleUseApprovalState() throws {
        let draft = try draft()
        let firstChallenge = VaultFillApprovalChallenge(draft: draft)
        let secondChallenge = VaultFillApprovalChallenge(draft: draft)
        XCTAssertEqual(firstChallenge.binding, secondChallenge.binding,
            "reconstructing the internal wrapper must preserve the original host challenge")
        let verifier = FakeTrustedVaultFillVerifier()
        let runtime = MutableVaultFillRuntime(
            state: VaultFillRuntimeSnapshot(binding: VaultFillCurrentBinding(draft: draft), status: .active),
            now: draft.createdAtWall.addingTimeInterval(10), monotonic: draft.createdAtMonotonic + 10)
        let first = VaultFillAuthorizationLifecycle(challenge: firstChallenge,
            currentRuntime: { runtime.snapshot() }, verifier: verifier,
            now: { runtime.now() }, monotonicNow: { runtime.monotonicNow() })
        let second = VaultFillAuthorizationLifecycle(challenge: secondChallenge,
            currentRuntime: { runtime.snapshot() }, verifier: verifier,
            now: { runtime.now() }, monotonicNow: { runtime.monotonicNow() })
        _ = try first.authorize(VaultFillApprovalReceipt(challenge: firstChallenge, proof: Data([1])))
        XCTAssertThrowsError(try second.authorize(VaultFillApprovalReceipt(challenge: secondChallenge, proof: Data([2])))) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .challengeAlreadyUsed)
        }
        XCTAssertEqual(verifier.biometricCalls, 1)
    }

    func testConcurrentAuthorizationAndPermitConsumptionRemainSingleUse() throws {
        let verifier = FakeTrustedVaultFillVerifier()
        let (lifecycle, challenge, _) = makeLifecycle(draft: try draft(), verifier: verifier)
        let receipt = VaultFillApprovalReceipt(challenge: challenge, proof: Data([1]))
        let results = ConcurrentPermitResults()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if let permit = try? lifecycle.authorize(receipt) { results.save(permit) }
        }
        let afterAuthorization = results.snapshot()
        XCTAssertEqual(afterAuthorization.0, 1)
        XCTAssertEqual(verifier.biometricCalls, 1)
        guard let permit = afterAuthorization.2 else { return XCTFail("one permit should be issued") }

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if (try? permit.consume()) != nil { results.recordConsume() }
        }
        XCTAssertEqual(results.snapshot().1, 1)
    }

    func testDenyStopTakeoverAndOtherInvalidationEventsInvalidatePendingAndUnusedPermit() throws {
        let reasons: [VaultFillInvalidationReason] = [.denied, .stop, .takeover, .navigation,
            .focusChanged, .disconnected, .taskRevoked, .targetChanged]
        for reason in reasons {
            let verifier = FakeTrustedVaultFillVerifier()
            let (lifecycle, challenge, _) = makeLifecycle(draft: try draft(), verifier: verifier)
            lifecycle.invalidate(reason)
            XCTAssertThrowsError(try lifecycle.authorize(VaultFillApprovalReceipt(challenge: challenge, proof: Data([1])))) {
                XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(reason))
            }
            XCTAssertEqual(verifier.biometricCalls, 0)
        }

        let verifier = FakeTrustedVaultFillVerifier()
        let (lifecycle, challenge, _) = makeLifecycle(draft: try draft(), verifier: verifier)
        let permit = try lifecycle.authorize(VaultFillApprovalReceipt(challenge: challenge, proof: Data([1])))
        lifecycle.invalidate(.stop)
        XCTAssertThrowsError(try permit.consume()) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.stop))
        }

        let changedVerifier = FakeTrustedVaultFillVerifier()
        let changed = makeLifecycle(draft: try draft(), verifier: changedVerifier)
        let changedPermit = try changed.0.authorize(
            VaultFillApprovalReceipt(challenge: changed.1, proof: Data([2])))
        var changedBinding = VaultFillCurrentBinding(draft: try draft())
        changedBinding.frameGeneration += 1
        changed.2.set(VaultFillRuntimeSnapshot(binding: changedBinding, status: .active))
        XCTAssertThrowsError(try changedPermit.consume()) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.targetChanged))
        }
        changed.2.set(VaultFillRuntimeSnapshot(binding: VaultFillCurrentBinding(draft: try draft()),
            status: .active))
        XCTAssertThrowsError(try changedPermit.consume()) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.targetChanged),
                "a permit invalidated by target drift must not become usable again")
        }
    }

    func testVerifierFailureAndInvalidationDuringVerificationNeverIssuePermit() throws {
        let verifier = FakeTrustedVaultFillVerifier()
        verifier.rejectVerification = true
        let (lifecycle, challenge, _) = makeLifecycle(draft: try draft(), verifier: verifier)
        XCTAssertThrowsError(try lifecycle.authorize(VaultFillApprovalReceipt(challenge: challenge, proof: Data([1])))) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .verificationFailed)
        }
        XCTAssertEqual(verifier.biometricCalls, 1)

        let during = FakeTrustedVaultFillVerifier()
        let (duringLifecycle, duringChallenge, _) = makeLifecycle(draft: try draft(), verifier: during)
        during.duringVerification = { duringLifecycle.invalidate(.takeover) }
        XCTAssertThrowsError(try duringLifecycle.authorize(
            VaultFillApprovalReceipt(challenge: duringChallenge, proof: Data([1])))) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.takeover))
        }

        let emptyVerifier = FakeTrustedVaultFillVerifier()
        let (emptyLifecycle, emptyChallenge, _) = makeLifecycle(draft: try draft(), verifier: emptyVerifier)
        XCTAssertThrowsError(try emptyLifecycle.authorize(
            VaultFillApprovalReceipt(challenge: emptyChallenge, proof: Data()))) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidReceipt)
        }
        XCTAssertEqual(emptyVerifier.biometricCalls, 0)
    }

    func testCancelledAuthorizationDuringVerifierInvalidatesChallengeAndCannotRetry() async throws {
        let verifier = FakeTrustedVaultFillVerifier()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        verifier.verificationEntered = entered
        verifier.verificationRelease = release
        let (lifecycle, challenge, _) = makeLifecycle(draft: try draft(), verifier: verifier)
        let receipt = VaultFillApprovalReceipt(challenge: challenge, proof: Data([1]))
        let task = Task.detached { () -> Result<VaultFillPermit, Error> in
            do { return .success(try lifecycle.authorize(receipt)) }
            catch { return .failure(error) }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        task.cancel()
        release.signal()
        let result = await task.value
        guard case .failure(let error) = result else { return XCTFail("cancelled authorization issued a permit") }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(verifier.biometricCalls, 1)

        let retry = Task.detached { () -> Result<VaultFillPermit, Error> in
            do { return .success(try lifecycle.authorize(receipt)) }
            catch { return .failure(error) }
        }
        guard case .failure(let retryError) = await retry.value else {
            return XCTFail("a cancelled challenge was reusable from a fresh task")
        }
        XCTAssertEqual(retryError as? VaultFillAuthorizationError, .invalidated(.taskRevoked))
        XCTAssertEqual(verifier.biometricCalls, 1)
    }

    func testCancelledBeforeAuthorizationSkipsVerifierAndInvalidatesChallenge() async throws {
        let verifier = FakeTrustedVaultFillVerifier()
        let (lifecycle, challenge, _) = makeLifecycle(draft: try draft(), verifier: verifier)
        let receipt = VaultFillApprovalReceipt(challenge: challenge, proof: Data([1]))
        let gate = DispatchSemaphore(value: 0)
        let task = Task.detached { () -> Result<VaultFillPermit, Error> in
            Self.waitForSignal(gate)
            do { return .success(try lifecycle.authorize(receipt)) }
            catch { return .failure(error) }
        }
        task.cancel()
        gate.signal()
        guard case .failure(let error) = await task.value else {
            return XCTFail("pre-cancelled authorization issued a permit")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(verifier.biometricCalls, 0)
        XCTAssertThrowsError(try lifecycle.authorize(receipt)) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.taskRevoked))
        }
    }

    func testCancellationBetweenAuthorizationAndConsumeInvalidatesPermit() async throws {
        let verifier = FakeTrustedVaultFillVerifier()
        let (lifecycle, challenge, _) = makeLifecycle(draft: try draft(), verifier: verifier)
        let permit = try lifecycle.authorize(VaultFillApprovalReceipt(challenge: challenge, proof: Data([1])))
        let gate = DispatchSemaphore(value: 0)
        let task = Task.detached { () -> Result<Void, Error> in
            Self.waitForSignal(gate)
            do { try permit.consume(); return .success(()) }
            catch { return .failure(error) }
        }
        task.cancel()
        gate.signal()
        guard case .failure(let error) = await task.value else {
            return XCTFail("cancelled task consumed the permit")
        }
        XCTAssertTrue(error is CancellationError)

        let retry = Task.detached { () -> Result<Void, Error> in
            do { try permit.consume(); return .success(()) }
            catch { return .failure(error) }
        }
        guard case .failure(let retryError) = await retry.value else {
            return XCTFail("a permit from a cancelled task was reusable")
        }
        XCTAssertEqual(retryError as? VaultFillAuthorizationError, .invalidated(.taskRevoked))
    }
}
