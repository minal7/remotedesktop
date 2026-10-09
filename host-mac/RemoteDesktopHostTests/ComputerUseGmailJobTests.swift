import Foundation
import ApplicationServices
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseGmailJobTests: XCTestCase {
    @MainActor
    func testHostNavigationRequiresMatchingFrontNativeWindow() throws {
        let app = try XCTUnwrap(ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari",
            processIdentifier: 42, codeIdentity: nil))
        let bounds = CGRect(x: 100, y: 50, width: 800, height: 600)
        let target = ComputerUseDefaultBrowserSession.Window(id: "owned", application: app,
            accessibilityElement: AXUIElementCreateApplication(42), identity: .init(
                applicationProcessIdentifier: 42, accessibilityWindowHash: 1, bounds: bounds))
        let row: [String: Any] = [kCGWindowOwnerPID as String: 42, kCGWindowLayer as String: 0,
            kCGWindowNumber as String: 101,
            kCGWindowBounds as String: CGRectCreateDictionaryRepresentation(bounds)]
        XCTAssertEqual(ComputerUseDefaultBrowserSession.matchingCGWindowNumber(target: target, windowInfo: [row]), 101)
        var other = row; other[kCGWindowNumber as String] = 102
        XCTAssertEqual(ComputerUseDefaultBrowserSession.matchingCGWindowNumber(target: target, windowInfo: [row, other]), 101,
            "Identical bounds on background windows must not hide the retained front window")
        XCTAssertEqual(ComputerUseDefaultBrowserSession.matchingCGWindowNumber(target: target, windowInfo: [other, row]), 102)
        other[kCGWindowBounds as String] = CGRectCreateDictionaryRepresentation(CGRect(x: 0, y: 0, width: 600, height: 400))
        XCTAssertNil(ComputerUseDefaultBrowserSession.matchingCGWindowNumber(target: target, windowInfo: [other, row]),
            "A matching background window must not grant authority when the front native window differs")
        other[kCGWindowOwnerPID as String] = 43
        XCTAssertNil(ComputerUseDefaultBrowserSession.matchingCGWindowNumber(target: target, windowInfo: [other]))
        XCTAssertEqual(ComputerUseDefaultBrowserSession.matchingCGWindowNumber(target: target, windowInfo: [other, row]), 101)
    }

    func testGoogleAuthenticationHandsOffWithoutModelOrCredentialInput() {
        XCTAssertNotNil(ComputerUseGmailNavigationPolicy.authenticationHandoff(
            url: "https://accounts.google.com/v3/signin/identifier", controlLabels: []))
        XCTAssertNotNil(ComputerUseGmailNavigationPolicy.authenticationHandoff(
            url: "https://mail.google.com/mail/u/0/", controlLabels: ["2-Step Verification"]))
        XCTAssertNil(ComputerUseGmailNavigationPolicy.authenticationHandoff(
            url: "https://mail.google.com/mail/u/0/#inbox", controlLabels: ["Compose", "Attach files"]))
    }

    @MainActor
    func testCopyAddressMenuTitleParserAcceptsObservedExactLabelOnly() {
        XCTAssertEqual(ComputerUseGmailRecipientVerifier.mailbox(
            fromCopyMenuTitle: #"Copy "spiderali97@gmail.com" Option+C"#), "spiderali97@gmail.com")
        XCTAssertEqual(ComputerUseGmailRecipientVerifier.mailbox(
            fromCopyMenuTitle: #"Copy "spiderali97@gmail.com""#), "spiderali97@gmail.com")
        XCTAssertNil(ComputerUseGmailRecipientVerifier.mailbox(
            fromCopyMenuTitle: #"Copy "spiderali97@gmail.com" More"#))
        XCTAssertNil(ComputerUseGmailRecipientVerifier.mailbox(
            fromCopyMenuTitle: #"Copy "spiderali97@gmail.com" Option+C extra"#))
        XCTAssertNil(ComputerUseGmailRecipientVerifier.mailbox(
            fromCopyMenuTitle: #"Copy "not-an-address" Option+C"#))
    }

    @MainActor
    func testRecipientMenuDismissalUsesEscapeOnlyWhileExactObservedMenuRemainsOpen() {
        let address = "alex@example.com"
        XCTAssertEqual(ComputerUseGmailRecipientVerifier.dismissalDecision(
            observation: .copyAddress(address), expectedAddress: address, escapeDispatched: false), .sendEscape)
        XCTAssertEqual(ComputerUseGmailRecipientVerifier.dismissalDecision(
            observation: .absent, expectedAddress: address, escapeDispatched: false), .menuAbsent,
            "An asynchronously vanished menu must not cause Escape to close the composer")
        XCTAssertEqual(ComputerUseGmailRecipientVerifier.dismissalDecision(
            observation: .copyAddress(address), expectedAddress: address, escapeDispatched: true), .stop,
            "A failed single Escape must not be repeated")
        XCTAssertEqual(ComputerUseGmailRecipientVerifier.dismissalDecision(
            observation: .copyAddress("other@example.com"), expectedAddress: address, escapeDispatched: false), .stop)
        XCTAssertEqual(ComputerUseGmailRecipientVerifier.dismissalDecision(
            observation: .unrecognized, expectedAddress: address, escapeDispatched: false), .stop,
            "An unrelated menu must never authorize Escape")
    }

    func testAmbiguousContactResolutionPublishesNameAndEmailChoices() async throws {
        let matches = [
            ComputerUseMailRecipients.Match(name: "Jordan Lee", address: "jordan.work@example.com"),
            ComputerUseMailRecipients.Match(name: "Jordan Lee", address: "jordan.personal@example.com"),
        ]
        let resolution = try await ComputerUseWebJobRequest.resolveRecipient(
            in: "Draft an email to Jordan Lee", trustedAccountControlLabel: nil,
            lookup: { _ in matches })
        guard case .choose(let name, let offeredMatches) = resolution else {
            return XCTFail("An ambiguous Contacts result must remain a choice, not select a recipient")
        }
        XCTAssertEqual(name, "Jordan Lee")
        let choices = try ComputerUseGmailRecipientChoiceSet(taskID: "gmail-contact-origin", matches: offeredMatches)
        XCTAssertEqual(choices.choices.map(\.label), ["Jordan Lee", "Jordan Lee"])
        XCTAssertEqual(choices.choices.map(\.detail), ["jordan.personal@example.com", "jordan.work@example.com"])
        XCTAssertEqual(choices.address(for: choices.choices[0], taskID: "gmail-contact-origin"), "jordan.personal@example.com",
            "Selecting the displayed option must map to its exact retained address")
    }

    func testGmailContactChoiceSetRejectsForeignAndStaleChoices() throws {
        let matches = [
            ComputerUseMailRecipients.Match(name: "Jordan Lee", address: "jordan.one@example.com"),
            ComputerUseMailRecipients.Match(name: "Jordan Lee", address: "jordan.two@example.com"),
        ]
        let origin = try ComputerUseGmailRecipientChoiceSet(taskID: "gmail-contact-origin", matches: matches)
        let replacement = try ComputerUseGmailRecipientChoiceSet(taskID: "gmail-contact-replacement", matches: matches)
        let foreign = try ComputerUseClarificationChoice(id: "foreign-choice", label: "Jordan Lee",
            detail: "jordan.one@example.com")
        XCTAssertNil(replacement.address(for: origin.choices[0], taskID: "gmail-contact-replacement"),
            "A choice ID from a retired question must not resolve in a replacement question")
        XCTAssertNil(origin.address(for: foreign, taskID: "gmail-contact-origin"),
            "A choice not offered by this retained set must be rejected")
        XCTAssertNil(origin.address(for: origin.choices[0], taskID: "foreign-task"),
            "A retained choice cannot cross task identity")
    }

    func testComposeURLUsesHostResolvedValuesAndEncodesReservedCharacters() throws {
        let job = try ComputerUseGmailJob(request: .init(to: ["alex+tag@example.com"], cc: ["cc@example.com"],
            bcc: [], subject: "Q&A + review", body: "Line one & line two +", fileDescription: "latest deck",
            sendRequested: false, existingDraftURL: nil))

        let components = try XCTUnwrap(job.composeURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "mail.google.com")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(query["to"], "alex+tag@example.com")
        XCTAssertEqual(query["cc"], "cc@example.com")
        XCTAssertEqual(query["su"], "Q&A + review")
        XCTAssertEqual(query["body"], "Line one & line two +")
        XCTAssertNil(query["bcc"])
        let wireURL = try XCTUnwrap(job.composeURL?.absoluteString)
        XCTAssertFalse(wireURL.contains("+"), "Literal plus signs must be percent-encoded in Gmail query values")
        XCTAssertTrue(wireURL.contains("%2B"))
    }

    func testComposeVerificationRequiresExactAddressSubjectAndBody() throws {
        let job = try ComputerUseGmailJob(request: .init(to: ["alex@example.com"], cc: [], bcc: [],
            subject: "Review", body: "Please review.", fileDescription: "", sendRequested: false,
            existingDraftURL: nil))
        let identity = ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari", processIdentifier: 42,
            codeIdentity: nil)!
        func observation(subject: String, body: String) -> ComputerUseDefaultBrowserPageReader.Observation {
            .init(id: "page", application: identity, url: "https://mail.google.com/mail/u/0/?view=cm",
                renderedAXText: "", controls: [], iframeContentMayBeOmitted: true, truncated: false,
                formFieldValues: [
                    .init(label: "To recipients", role: "AXTextField", value: "alex@example.com"),
                    .init(label: "Subject", role: "AXTextField", value: subject),
                    .init(label: "Message Body", role: "AXTextArea", value: body),
                ])
        }
        XCTAssertTrue(job.verifiesCompose(observation(subject: "Review", body: "Please review.")))
        XCTAssertFalse(job.verifiesCompose(observation(subject: "Review copy", body: "Please review.")))
        XCTAssertFalse(job.verifiesCompose(observation(subject: "Review", body: "Please review. ")))
        let wrongRecipient = ComputerUseDefaultBrowserPageReader.Observation(id: "wrong", application: identity,
            url: "https://mail.google.com/mail/u/0/?view=cm", renderedAXText: "alex@example.com",
            controls: [], iframeContentMayBeOmitted: true, truncated: false,
            exactTextValues: ["alex@example.com"], formFieldValues: [
                .init(label: "To recipients", role: "AXTextField", value: "other@example.com"),
                .init(label: "Subject", role: "AXTextField", value: "Review"),
                .init(label: "Message Body", role: "AXTextArea", value: "Please review."),
            ])
        XCTAssertFalse(job.verifiesCompose(wrongRecipient), "Page-wide text cannot prove the To field")
        let extraRecipient = ComputerUseDefaultBrowserPageReader.Observation(id: "extra", application: identity,
            url: "https://mail.google.com/mail/u/0/?view=cm", renderedAXText: "", controls: [],
            iframeContentMayBeOmitted: true, truncated: false, formFieldValues: [
                .init(label: "To recipients", role: "AXTextField", value: "alex@example.com, extra@example.com"),
                .init(label: "CC recipients", role: "AXTextField", value: "unexpected@example.com"),
                .init(label: "Subject", role: "AXTextField", value: "Review"),
                .init(label: "Message Body", role: "AXTextArea", value: "Please review."),
            ])
        XCTAssertFalse(job.verifiesCompose(extraRecipient), "Recipient checks must reject extra To and CC addresses")
    }

    func testExistingDraftMustStayOnGmailAndSendPresentationUsesResolvedFile() throws {
        XCTAssertThrowsError(try ComputerUseGmailJob(request: .init(to: ["alex@example.com"], cc: [], bcc: [],
            subject: "Review", body: "Please review.", fileDescription: "deck", sendRequested: true,
            existingDraftURL: URL(string: "https://example.com/draft"))))

        var job = try ComputerUseGmailJob(request: .init(to: ["alex@example.com"], cc: [], bcc: [],
            subject: "Review", body: "Please review.", fileDescription: "deck", sendRequested: true,
            existingDraftURL: nil))
        try job.selectAttachment(.init(candidateID: "candidate-1", displayName: "Review.pptx", byteCount: 1_024))
        let presentation = try XCTUnwrap(job.sendApprovalPresentation())
        XCTAssertEqual(presentation.message, "Send this email through Gmail?")
        XCTAssertEqual(presentation.confirmLabel, "Send email")
        XCTAssertTrue(presentation.details.contains(.init(label: "To", value: "alex@example.com")))
        XCTAssertTrue(presentation.details.contains(.init(label: "Attachment", value: "Review.pptx (1024 bytes)")))
    }

    func testSendWithoutAttachmentStillPresentsExactFields() throws {
        let job = try ComputerUseGmailJob(request: .init(to: ["alex@example.com"], cc: [], bcc: [],
            subject: "Review", body: "Please review.", fileDescription: "", sendRequested: true,
            existingDraftURL: nil))
        let presentation = try XCTUnwrap(job.sendApprovalPresentation())
        XCTAssertTrue(presentation.details.contains(.init(label: "To", value: "alex@example.com")))
        XCTAssertTrue(presentation.details.contains(.init(label: "Message", value: "Please review.")))
        XCTAssertFalse(presentation.details.contains(where: { $0.label == "Attachment" }))
    }

    func testAttachmentEvidenceKeepsNameAndSizeTogether() throws {
        var job = try ComputerUseGmailJob(request: .init(to: ["alex@example.com"], cc: [], bcc: [],
            subject: "Review", body: "Please review.", fileDescription: "deck", sendRequested: false,
            existingDraftURL: nil))
        try job.selectAttachment(.init(candidateID: "candidate-1", displayName: "Review.pptx", byteCount: 1_024))
        var formatter = ByteCountFormatter(); formatter.countStyle = .file
        let size = formatter.string(fromByteCount: 1_024)
        let identity = ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari", processIdentifier: 42,
            codeIdentity: nil)!
        func observation(_ values: [String]) -> ComputerUseDefaultBrowserPageReader.Observation {
            .init(id: "page", application: identity, url: "https://mail.google.com/mail/u/0/?view=cm",
                renderedAXText: "", controls: [], iframeContentMayBeOmitted: true, truncated: false,
                exactTextValues: values)
        }
        XCTAssertTrue(job.verifiesAttachment(observation(["Review.pptx, \(size)"])))
        XCTAssertFalse(job.verifiesAttachment(observation(["Review.pptx", size])),
            "A separate page-size string does not prove the selected attachment chip")
    }
}
