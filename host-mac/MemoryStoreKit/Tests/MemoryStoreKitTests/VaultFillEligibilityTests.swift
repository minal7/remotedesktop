import Foundation
import XCTest
@testable import MemoryStoreKit

final class VaultFillEligibilityTests: XCTestCase {
    private let handle = VaultItemID(uuid: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!)
    private let authority = VaultFillOwnerTaskAuthority(ownerID: "owner", sessionID: "session",
        taskID: "task", revision: 4, intent: .ownerTaskExplicitlyRequestedFill)

    private func webTarget(_ overrides: (inout VaultFillWebTargetInput) -> Void = { _ in }) -> VaultFillTargetDescriptor {
        var input = VaultFillWebTargetInput(
            reference: "element-opaque-1", navigationGeneration: 3, frameGeneration: 8,
            topLevelOrigin: "https://checkout.example:443", frameOrigin: "https://checkout.example",
            autocomplete: "section-payment billing cc-number", inputType: .text,
            purpose: .typedFormField, contentEditable: false, visible: true, editable: true, secure: false)
        overrides(&input)
        return .web(input)
    }

    private func request(_ field: VaultSecretField = .cardNumber,
                         kind: VaultFillItemKind = .paymentCard) -> VaultFillRequest {
        VaultFillRequest(handle: handle, itemKind: kind, field: field)
    }

    private func webOrigin(_ draft: VaultFillApprovalDraft) -> String? {
        guard case .web(let origin) = draft.targetIdentity else { return nil }
        return origin.serialized
    }

    private func nativeIdentity(_ draft: VaultFillApprovalDraft) -> VaultFillNativeIdentity? {
        guard case .native(let identity) = draft.targetIdentity else { return nil }
        return identity
    }

    func testEligiblePaymentProducesValueFreeBoundDraftWithNoExecutionFlag() throws {
        let result = VaultFillEligibility.assess(authority: authority, target: webTarget(),
            request: request(), now: Date(timeIntervalSince1970: 1_800_000_000))
        let draft = try XCTUnwrap(result.draft)
        XCTAssertEqual(draft.taskID, "task")
        XCTAssertEqual(draft.sessionID, "session")
        XCTAssertEqual(draft.revision, 4)
        XCTAssertEqual(draft.targetReference, "element-opaque-1")
        XCTAssertEqual(draft.navigationGeneration, 3)
        XCTAssertEqual(draft.frameGeneration, 8)
        XCTAssertEqual(draft.handleID, handle)
        XCTAssertEqual(draft.field, .cardNumber)
        XCTAssertEqual(webOrigin(draft), "https://checkout.example")
        XCTAssertEqual(draft.expiresAt.timeIntervalSince1970, 1_800_000_030)
        XCTAssertEqual(String(describing: draft), "<vault-fill-approval-draft>")
        XCTAssertEqual(String(reflecting: draft), "<vault-fill-approval-draft>")
        XCTAssertFalse(String(reflecting: draft).contains("approved"))
    }

    func testExactCanonicalHTTPSOriginIncludesNondefaultPortAndRejectsCrossOriginFrames() throws {
        let sameOrigin = VaultFillEligibility.assess(authority: authority,
            target: webTarget { $0.topLevelOrigin = "https://shop.example:8443"; $0.frameOrigin = "https://shop.example:8443" },
            request: request(), now: Date())
        XCTAssertEqual(webOrigin(try XCTUnwrap(sameOrigin.draft)), "https://shop.example:8443")

        let crossOrigin = VaultFillEligibility.assess(authority: authority,
            target: webTarget { $0.frameOrigin = "https://iframe.example" }, request: request(), now: Date())
        XCTAssertEqual(crossOrigin.denial, .crossOriginFrame)
    }

    func testRejectsUnsafeOrNonCanonicalOriginComponents() {
        let badOrigins = [
            "http://checkout.example", "https://user@checkout.example", "https://checkout.example/path",
            "https://checkout.example/?q=1", "https://checkout.example/#fragment", "https://*.example",
            "null", "https://checkout.example:0", "https://checkout.example:65536",
            "https://checkout.example/",
            "https://checkout..example", "https://-checkout.example", "https://checkout-.example",
            "https://checkout%2eexample", "https://éxample.test", "https://[2001:db8::1]",
            "https://127.0.0.01", "https://127.1", "https://0177.0.0.1",
            "https://0x7f000001", "https://0x7f.0.0.1", "https://example.123"
        ]
        for origin in badOrigins {
            let result = VaultFillEligibility.assess(authority: authority,
                target: webTarget { $0.topLevelOrigin = origin; $0.frameOrigin = origin },
                request: request(), now: Date())
            XCTAssertEqual(result.denial, .invalidOrigin, "origin rejected: \(origin)")
        }
    }

    func testLookalikeHostRemainsItsOwnExactOrigin() throws {
        let lookalike = VaultFillEligibility.assess(authority: authority,
            target: webTarget { $0.topLevelOrigin = "https://checkout.example.attacker.test"; $0.frameOrigin = "https://checkout.example.attacker.test" },
            request: request(), now: Date())
        XCTAssertEqual(webOrigin(try XCTUnwrap(lookalike.draft)),
                       "https://checkout.example.attacker.test")
        XCTAssertNotEqual(webOrigin(try XCTUnwrap(lookalike.draft)), "https://checkout.example")
    }

    func testHTMLAutocompleteRequiresFullSupportedFieldSequenceAndExactFieldMatch() {
        let wrongField = VaultFillEligibility.assess(authority: authority,
            target: webTarget { $0.autocomplete = "section-payment billing cc-name" },
            request: request(), now: Date())
        XCTAssertEqual(wrongField.denial, .fieldMismatch)

        let phoneContactHint = VaultFillEligibility.assess(authority: authority,
            target: webTarget { $0.autocomplete = "home tel"; $0.inputType = .tel },
            request: request(.phoneNumber, kind: .phone), now: Date())
        XCTAssertNotNil(phoneContactHint.draft)

        let asciiWhitespace = VaultFillEligibility.assess(authority: authority,
            target: webTarget { $0.autocomplete = "billing\tcc-number" }, request: request(), now: Date())
        XCTAssertNotNil(asciiWhitespace.draft)

        for token in ["fake-cc-number", "search cc-number", "billing nonsense cc-number",
                      "section- cc-number", "cc-number webauthn bad", "cc-number cc-name",
                      "home cc-number", "fax postal-code", "billing\u{00A0}cc-number",
                      "billing\u{2003}cc-number", "billing\u{200B}cc-number"] {
            let result = VaultFillEligibility.assess(authority: authority,
                target: webTarget { $0.autocomplete = token }, request: request(), now: Date())
            XCTAssertEqual(result.denial, .unclassifiedTarget, "token sequence rejected: \(token)")
        }
    }

    func testRejectsProhibitedAndUnsafeWebTargets() {
        let cases: [(String, (inout VaultFillWebTargetInput) -> Void)] = [
            ("search input", { $0.inputType = .search }),
            ("URL input", { $0.inputType = .url }),
            ("chat purpose despite card autocomplete", { $0.purpose = .chat }),
            ("free text purpose despite card autocomplete", { $0.purpose = .freeText }),
            ("unknown purpose", { $0.purpose = .unknown }),
            ("contenteditable", { $0.contentEditable = true }),
            ("hidden", { $0.visible = false }),
            ("read only", { $0.editable = false }),
            ("secure field", { $0.secure = true }),
            ("negative navigation generation", { $0.navigationGeneration = -1 }),
            ("empty ref", { $0.reference = "" })
        ]
        for (name, mutate) in cases {
            let result = VaultFillEligibility.assess(authority: authority,
                target: webTarget(mutate), request: request(), now: Date())
            XCTAssertNotNil(result.denial, name)
        }
    }

    func testCardFieldCannotBeRequestedFromAddressHandleAndPaymentIsNotRemembered() throws {
        let mismatch = VaultFillEligibility.assess(authority: authority, target: webTarget(),
            request: request(.cardNumber, kind: .address), now: Date())
        XCTAssertEqual(mismatch.denial, .itemFieldMismatch)

        let cardExpiry = VaultFillEligibility.assess(authority: authority, target: webTarget {
            $0.autocomplete = "cc-exp-month"
        }, request: request(.cardExpiryMonth), now: Date())
        XCTAssertEqual(try XCTUnwrap(cardExpiry.draft).consentClass, .freshPhoneBiometricRequired)
        XCTAssertNil(VaultFillEligibility.assess(authority: authority, target: webTarget(),
            request: request(.membershipNumber, kind: .membership), now: Date()).draft)
    }

    func testCVVAndPasswordsHaveNoRepresentableApproval() {
        XCTAssertFalse(VaultSecretField.allCases.contains { $0.rawValue.localizedCaseInsensitiveContains("cvv") })
        XCTAssertFalse(VaultSecretField.allCases.contains { $0.rawValue.localizedCaseInsensitiveContains("password") })
        XCTAssertEqual(VaultFillEligibility.assess(authority: authority, target: webTarget(),
            request: request(.identityNumber, kind: .identity), now: Date()).denial, .unsupportedField)
    }

    func testNativeRequiresExactBundleWindowAndTypedAXRoleLabel() throws {
        let native = VaultFillTargetDescriptor.native(VaultFillNativeTargetInput(
            reference: "ax-ref-7", navigationGeneration: 0, frameGeneration: 2,
            bundleID: "com.example.checkout", windowIdentity: "window-opaque-9",
            windowTitle: "Checkout", role: .textField, label: "Card number",
            purpose: .typedFormField, visible: true, editable: true, secure: false, valueSettable: true))
        let result = VaultFillEligibility.assess(authority: authority, target: native,
            request: request(), now: Date())
        let draft = try XCTUnwrap(result.draft)
        XCTAssertEqual(nativeIdentity(draft)?.bundleID, "com.example.checkout")
        XCTAssertEqual(nativeIdentity(draft)?.windowIdentity, "window-opaque-9")

        let altered = VaultFillEligibility.assess(authority: authority,
            target: .native(VaultFillNativeTargetInput(reference: "ax-ref-7", navigationGeneration: 0,
                frameGeneration: 2, bundleID: "com.example.checkout", windowIdentity: "window-opaque-9",
                windowTitle: "Checkout", role: .textField, label: "Credit card maybe",
                purpose: .typedFormField, visible: true, editable: true, secure: false,
                valueSettable: true)), request: request(), now: Date())
        XCTAssertEqual(altered.denial, .unclassifiedTarget)

        let prohibitedPurposes: [VaultFillControlPurpose] = [.chat, .freeText, .search, .urlBar, .unknown]
        for purpose in prohibitedPurposes {
            let prohibited = VaultFillEligibility.assess(authority: authority,
                target: .native(VaultFillNativeTargetInput(reference: "ax-ref-7", navigationGeneration: 0,
                    frameGeneration: 2, bundleID: "com.example.checkout", windowIdentity: "window-opaque-9",
                    windowTitle: "Checkout", role: .textField, label: "Card number", purpose: purpose,
                    visible: true, editable: true, secure: false, valueSettable: true)),
                request: request(), now: Date())
            XCTAssertEqual(prohibited.denial, .prohibitedTarget, "native purpose rejected: \(purpose)")
        }
    }

    func testAuthorityAndClockValidationFailClosed() {
        let deniedAuthority = VaultFillOwnerTaskAuthority(ownerID: "owner", sessionID: "session",
            taskID: "task", revision: 4, intent: .pageRequestedFill)
        XCTAssertEqual(VaultFillEligibility.assess(authority: deniedAuthority, target: webTarget(),
            request: request(), now: Date()).denial, .notOwnerRequested)

        let empty = VaultFillOwnerTaskAuthority(ownerID: "", sessionID: "session",
            taskID: "task", revision: 4, intent: .ownerTaskExplicitlyRequestedFill)
        XCTAssertEqual(VaultFillEligibility.assess(authority: empty, target: webTarget(),
            request: request(), now: Date()).denial, .invalidAuthority)
        XCTAssertEqual(VaultFillEligibility.assess(authority: authority, target: webTarget(),
            request: request(), now: Date(timeIntervalSince1970: .infinity)).denial, .invalidClock)
    }
}
