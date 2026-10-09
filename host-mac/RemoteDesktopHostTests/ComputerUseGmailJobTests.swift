import Foundation
import AppKit
import ApplicationServices
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseGmailJobTests: XCTestCase {
    func testGmailAccountSnapshotUsesOnlyValidatedSignedInNumericRoutes() throws {
        let snapshot = try XCTUnwrap(ComputerUseGmailAccountDirectory.snapshot(
            currentLabel: "Google Account: Test Current (current@example.com), Google membership",
            currentURL: "https://mail.google.com/mail/u/0/#inbox",
            links: [
                .init(label: "Test Other other@example.com (opens a new tab)",
                    url: "https://mail.google.com/mail/u/1/"),
                .init(label: "Signed out · Another Person other@example.com", url: "https://mail.google.com/mail/u/2/"),
                .init(label: "Add another account add@example.com", url: "https://accounts.google.com/AccountChooser"),
                .init(label: "Foreign account foreign@example.com", url: "https://drive.google.com/mail/u/3/"),
            ]))
        XCTAssertEqual(snapshot.current, .init(email: "current@example.com", displayName: "Test Current", index: 0))
        XCTAssertEqual(snapshot.accounts, [
            .init(email: "current@example.com", displayName: "Test Current", index: 0),
            .init(email: "other@example.com", displayName: "Test Other", index: 1),
        ])
    }

    func testGmailAccountSnapshotRejectsAmbiguousIdentityBindings() {
        let header = "Google Account: Current (current@example.com), Google membership"
        XCTAssertNil(ComputerUseGmailAccountDirectory.snapshot(currentLabel: header,
            currentURL: "https://mail.google.com/mail/u/0/", links: [
                .init(label: "Other other@example.com", url: "https://mail.google.com/mail/u/0/"),
            ]), "One numeric account route cannot identify two different accounts")
        XCTAssertNil(ComputerUseGmailAccountDirectory.snapshot(currentLabel: header,
            currentURL: "https://mail.google.com/mail/u/0/", links: [
                .init(label: "Current current@example.com", url: "https://mail.google.com/mail/u/1/"),
            ]), "One email cannot map to two numeric account routes")
        XCTAssertNil(ComputerUseGmailAccountDirectory.snapshot(currentLabel: "Account current@example.com",
            currentURL: "https://mail.google.com/mail/u/0/", links: []))
    }

    func testGmailAccountPreferenceMapsByObservedEmailAndFailsClosedWhenMissing() throws {
        let current = ComputerUseGmailAccountDirectory.Account(email: "current@example.com",
            displayName: "Current", index: 0)
        let preferred = ComputerUseGmailAccountDirectory.Account(email: "preferred@example.com",
            displayName: "Preferred", index: 2)
        let snapshot = ComputerUseGmailAccountDirectory.Snapshot(current: current,
            accounts: [current, preferred])
        XCTAssertEqual(ComputerUseGmailAccountDirectory.resolvePreference(nil, in: snapshot), .askUser)
        XCTAssertEqual(ComputerUseGmailAccountDirectory.resolvePreference("PREFERRED@example.com", in: snapshot),
            .selected(preferred), "Remembered identity follows the freshly observed email-to-route mapping")
        XCTAssertEqual(ComputerUseGmailAccountDirectory.resolvePreference("missing@example.com", in: snapshot), .unavailable)
    }

    func testGmailAccountRouteSupportsComposeQueryButAccountMenuLinksStayBare() {
        XCTAssertEqual(ComputerUseGmailAccountDirectory.accountIndex(
            from: "https://mail.google.com/mail/u/1/?view=cm&to=person%40example.com"), 1)
        XCTAssertEqual(ComputerUseGmailAccountDirectory.accountIndex(
            from: "https://mail.google.com/mail/u/0/#inbox"), 0)
        XCTAssertNil(ComputerUseGmailAccountDirectory.accountIndex(
            from: "https://mail.google.com/mail/u/1/?view=cm", requireAccountLink: true))
        XCTAssertNil(ComputerUseGmailAccountDirectory.accountIndex(
            from: "https://mail.google.com.evil.test/mail/u/1/"))
        XCTAssertNil(ComputerUseGmailAccountDirectory.accountIndex(
            from: "https://user@mail.google.com/mail/u/1/"))
    }

    func testStandaloneGmailComposerAccountProofRequiresExactIndexedGmailWindowIdentity() {
        let selected = ComputerUseGmailAccountDirectory.Account(email: "current@example.com",
            displayName: "Current", index: 0)
        let composeURL = "https://mail.google.com/mail/u/0/?fs=1&to=test%40example.com&su=Review&tf=cm"
        XCTAssertTrue(ComputerUseGmailAccountDirectory.confirmsActiveAccount(
            currentURL: composeURL,
            windowTitle: "Compose Mail - current@example.com - Gmail",
            accountControlLabel: nil, expected: selected))

        XCTAssertFalse(ComputerUseGmailAccountDirectory.confirmsActiveAccount(
            currentURL: composeURL,
            windowTitle: "Compose Mail - other@example.com - Gmail",
            accountControlLabel: nil, expected: selected), "A matching URL index cannot override a different title identity")
        XCTAssertFalse(ComputerUseGmailAccountDirectory.confirmsActiveAccount(
            currentURL: "https://mail.google.com/mail/u/1/?fs=1&tf=cm",
            windowTitle: "Compose Mail - current@example.com - Gmail",
            accountControlLabel: nil, expected: selected), "The exact Gmail identity must stay bound to its selected numeric route")
        XCTAssertFalse(ComputerUseGmailAccountDirectory.confirmsActiveAccount(
            currentURL: composeURL,
            windowTitle: "Compose Mail - current@example.com - Gmail Please review this draft",
            accountControlLabel: nil, expected: selected), "Body text or an appended title cannot spoof the exact outer window title")
        XCTAssertFalse(ComputerUseGmailAccountDirectory.confirmsActiveAccount(
            currentURL: "https://mail.google.com.evil.test/mail/u/0/?fs=1&tf=cm",
            windowTitle: "Compose Mail - current@example.com - Gmail",
            accountControlLabel: nil, expected: selected))
        XCTAssertFalse(ComputerUseGmailAccountDirectory.confirmsActiveAccount(
            currentURL: "https://mail.google.com/mail/u/0/#inbox",
            windowTitle: "Inbox (3) - current@example.com - Gmail",
            accountControlLabel: nil, expected: selected), "An account-looking inbox title is not standalone composer proof")
        XCTAssertFalse(ComputerUseGmailAccountDirectory.confirmsActiveAccount(
            currentURL: composeURL,
            windowTitle: "Compose Mail - current@example.com - Gmail",
            accountControlLabel: "Google Account: other@example.com, Google membership", expected: selected),
            "A conflicting account button must invalidate the title proof")
        XCTAssertFalse(ComputerUseGmailAccountDirectory.confirmsActiveAccount(
            currentURL: "https://mail.google.com/mail/u/0/?fs=1&tf=cm&tf=cm",
            windowTitle: "Compose Mail - current@example.com - Gmail",
            accountControlLabel: nil, expected: selected), "Duplicate composer markers are ambiguous")
    }

    func testGmailComposeVerificationRejectsDuplicateComposerFieldsWithMixedValues() throws {
        let account = ComputerUseGmailAccountDirectory.Account(email: "current@example.com",
            displayName: "Current", index: 0)
        let job = try ComputerUseGmailJob(request: .init(to: ["recipient@example.com"], cc: [], bcc: [],
            subject: "Review", body: "Please review.", fileDescription: "", sendRequested: false,
            account: account))
        let identity = ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari", processIdentifier: 42,
            codeIdentity: nil)!
        let duplicateComposer = ComputerUseDefaultBrowserPageReader.Observation(id: "two-composers",
            application: identity, url: "https://mail.google.com/mail/u/0/?fs=1&tf=cm",
            renderedAXText: "", controls: [], iframeContentMayBeOmitted: true, truncated: false,
            formFieldValues: [
                .init(label: "To recipients", role: "AXTextField", value: "recipient@example.com"),
                .init(label: "Subject", role: "AXTextField", value: "Review"),
                .init(label: "Subject", role: "AXTextField", value: "Different draft"),
                .init(label: "Message Body", role: "AXTextArea", value: "Please review."),
                .init(label: "Message Body", role: "AXTextArea", value: "Different body"),
            ])
        XCTAssertFalse(job.verifiesCompose(duplicateComposer), "Two matching composers are ambiguous even when their values agree")
    }

    func testGmailComposeVerificationIgnoresUnrelatedWritingAssistantTextArea() throws {
        let account = ComputerUseGmailAccountDirectory.Account(email: "current@example.com",
            displayName: "Current", index: 0)
        let job = try ComputerUseGmailJob(request: .init(to: ["recipient@example.com"], cc: [], bcc: [],
            subject: "Review", body: "Please review.", fileDescription: "", sendRequested: false,
            account: account))
        let identity = ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari", processIdentifier: 42,
            codeIdentity: nil)!
        let standalone = ComputerUseDefaultBrowserPageReader.Observation(id: "standalone-compose",
            application: identity, url: "https://mail.google.com/mail/u/0/?fs=1&tf=cm",
            renderedAXText: "", controls: [], iframeContentMayBeOmitted: true, truncated: false,
            formFieldValues: [
                .init(label: "To recipients", role: "AXTextField", value: "recipient@example.com"),
                .init(label: "Subject", role: "AXTextField", value: "Review"),
                .init(label: "Message Body", role: "AXTextArea", value: "Please review."),
                .init(label: "Describe your message", role: "AXTextArea", value: "Write with AI"),
            ])
        XCTAssertTrue(job.verifiesComposeContents(standalone),
            "The Gmail writing assistant editor is not the message body field")
    }

    func testGmailDraftRecoveryRequiresOneExactSubjectCellAndCompleteScan() {
        let subject = "Quarterly review"
        XCTAssertEqual(ComputerUseGmailJob.uniqueDraftSubjectCellIndex(
            rowTexts: ["Other draft", subject], scanComplete: true, subject: subject), 1)
        XCTAssertNil(ComputerUseGmailJob.uniqueDraftSubjectCellIndex(
            rowTexts: [subject, subject], scanComplete: true, subject: subject))
        XCTAssertNil(ComputerUseGmailJob.uniqueDraftSubjectCellIndex(
            rowTexts: [subject], scanComplete: false, subject: subject))
        XCTAssertNil(ComputerUseGmailJob.uniqueDraftSubjectCellIndex(
            rowTexts: ["Quarterly review draft"], scanComplete: true, subject: subject))
    }

    @MainActor
    func testGmailAccountPreferenceStoresOnlyExplicitlySelectedEmail() throws {
        let suite = "ComputerUseGmailAccountPreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ComputerUseGmailAccountPreferences(defaults: defaults, key: "selected")
        let account = ComputerUseGmailAccountDirectory.Account(email: "preferred@example.com",
            displayName: "Preferred Account", index: 1)
        XCTAssertNil(preferences.preferredEmail)
        preferences.remember(account)
        XCTAssertEqual(preferences.preferredEmail, "preferred@example.com")
    }

    func testGmailAccountChoiceIsBoundToTaskAndExactAccountEmail() throws {
        let accounts = [
            ComputerUseGmailAccountDirectory.Account(email: "one@example.com", displayName: "One", index: 0),
            ComputerUseGmailAccountDirectory.Account(email: "two@example.com", displayName: "Two", index: 1),
        ]
        let choices = try ComputerUseGmailAccountChoiceSet(taskID: "account-choice-origin", accounts: accounts)
        XCTAssertEqual(choices.choices.map(\.id).count, 2)
        XCTAssertTrue(choices.choices.allSatisfy { $0.id.hasPrefix("gmail-account-") })
        XCTAssertEqual(choices.choices.map(\.detail), ["one@example.com", "two@example.com"])
        XCTAssertEqual(choices.account(for: choices.choices[1], taskID: "account-choice-origin"), accounts[1])
        XCTAssertNil(choices.account(for: choices.choices[1], taskID: "foreign-task"))
        let forged = try ComputerUseClarificationChoice(id: choices.choices[1].id,
            label: choices.choices[1].label, detail: "forged@example.com")
        XCTAssertNil(choices.account(for: forged, taskID: "account-choice-origin"))
    }

    func testGmailDraftCompositionAndVerificationStayOnSelectedAccountRoute() throws {
        let account = ComputerUseGmailAccountDirectory.Account(email: "preferred@example.com",
            displayName: "Preferred Account", index: 1)
        let job = try ComputerUseGmailJob(request: .init(to: ["recipient@example.com"], cc: [], bcc: [],
            subject: "Review", body: "Please review.", fileDescription: "", sendRequested: false,
            existingDraftURL: nil, account: account))
        let composeURL = try XCTUnwrap(job.composeURL)
        XCTAssertEqual(ComputerUseGmailAccountDirectory.accountIndex(from: composeURL.absoluteString), 1)
        XCTAssertTrue(composeURL.absoluteString.contains("view=cm"))
        let identity = ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari", processIdentifier: 42,
            codeIdentity: nil)!
        func observation(_ url: String) -> ComputerUseDefaultBrowserPageReader.Observation {
            .init(id: "compose", application: identity, url: url, renderedAXText: "", controls: [],
                iframeContentMayBeOmitted: true, truncated: false, formFieldValues: [
                    .init(label: "To recipients", role: "AXTextField", value: "recipient@example.com"),
                    .init(label: "Subject", role: "AXTextField", value: "Review"),
                    .init(label: "Message Body", role: "AXTextArea", value: "Please review."),
                ])
        }
        XCTAssertTrue(job.verifiesCompose(observation("https://mail.google.com/mail/u/1/?view=cm")))
        XCTAssertFalse(job.verifiesCompose(observation("https://mail.google.com/mail/u/0/?view=cm")))
        XCTAssertNoThrow(try ComputerUseGmailJob(request: .init(to: ["recipient@example.com"], cc: [], bcc: [],
            subject: "Review", body: "Please review.", fileDescription: "", sendRequested: false,
            existingDraftURL: URL(string: "https://mail.google.com/mail/u/1/?view=cm&to=recipient%40example.com"),
            account: account)))
        XCTAssertThrowsError(try ComputerUseGmailJob(request: .init(to: ["recipient@example.com"], cc: [], bcc: [],
            subject: "Review", body: "Please review.", fileDescription: "", sendRequested: false,
            existingDraftURL: URL(string: "https://mail.google.com/mail/u/0/#drafts?compose=Abc123"), account: account)))
    }

    @MainActor
    func testOptInGmailAccountMenuCaptureProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RUN_GMAIL_ACCOUNT_CAPTURE_PROBE"] == "1" else {
            throw XCTSkip("Opt-in read-only capture of a manually opened Gmail account menu")
        }
        let expectedCurrent = try XCTUnwrap(env["GMAIL_ACCOUNT_EXPECTED_CURRENT_EMAIL"])
        let expectedOther = try XCTUnwrap(env["GMAIL_ACCOUNT_EXPECTED_OTHER_EMAIL"])
        let tracePath = try XCTUnwrap(env["GMAIL_ACCOUNT_CAPTURE_TRACE"])
        let traceRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RemoteDesktopHost/Traces", isDirectory: true)
            .standardizedFileURL
        let traceURL = URL(fileURLWithPath: tracePath).standardizedFileURL
        guard traceURL.path.hasPrefix(traceRoot.path + "/") else {
            return XCTFail("Capture trace must be written under the external Remote Desktop Host trace directory")
        }
        try FileManager.default.createDirectory(at: traceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let defaultHandler = try XCTUnwrap(ComputerUseDefaultBrowserTarget.currentDefaultHTTPSHandler())
        let initialFrontmost = NSWorkspace.shared.frontmostApplication
        let readiness: [String: Any] = [
            "default_browser_bundle": defaultHandler.bundleIdentifier,
            "default_browser_path": defaultHandler.bundleURL.standardizedFileURL.path,
            "initial_frontmost_bundle": initialFrontmost?.bundleIdentifier ?? "none",
            "initial_frontmost_path": initialFrontmost?.bundleURL?.standardizedFileURL.path ?? "none",
        ]
        let readinessData = try JSONSerialization.data(withJSONObject: readiness, options: [.sortedKeys])
        let readyURL = URL(fileURLWithPath: traceURL.path + ".ready")
        try readinessData.write(to: readyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: readyURL.path)

        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var foreground: (ComputerUseDefaultBrowserTarget.Handler,
            ComputerUseApplicationIdentity, ComputerUseFrontmostWindowCaptureIdentity)?
        while foreground == nil, ContinuousClock.now < deadline {
            foreground = ComputerUseDefaultBrowserTarget.currentDefaultHandlerForegroundWindow()
            if foreground == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        guard let (handler, app, focusedWindow) = foreground else {
            let currentFrontmost = NSWorkspace.shared.frontmostApplication
            return XCTFail("Timed out waiting for observed default Safari window; frontmostBundle=\(currentFrontmost?.bundleIdentifier ?? "none"), defaultBundle=\(defaultHandler.bundleIdentifier)")
        }
        let frontmost = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        XCTAssertFalse(frontmost.isTerminated)
        XCTAssertEqual(frontmost.bundleIdentifier, handler.bundleIdentifier)
        XCTAssertEqual(frontmost.processIdentifier, app.processIdentifier)
        let windows = try ComputerUseDefaultBrowserSession.captureWindowsForApplication(app)
        let retained = try XCTUnwrap(windows.windows.first(where: { $0.identity == focusedWindow }))
        XCTAssertEqual(windows.focusedWindowID, retained.id)
        let page = try XCTUnwrap(ComputerUseDefaultBrowserPageReader().read(window: retained.accessibilityElement,
            application: app, mayAct: { true }))
        guard let pageComponents = URLComponents(string: page.url),
              pageComponents.host?.lowercased() == "mail.google.com",
              pageComponents.fragment?.localizedCaseInsensitiveContains("inbox") == true,
              ComputerUseGmailAccountDirectory.accountIndex(from: page.url) != nil else {
            return XCTFail("The frontmost browser must already show a Gmail account route")
        }
        guard case .accounts(let snapshot) = try ComputerUseGmailAccountDirectory.readMenu(
            window: retained.accessibilityElement, application: app, currentURL: page.url,
            closeMenu: false, revalidate: {}) else {
            return XCTFail("The manually opened signed-in account menu could not be read")
        }
        XCTAssertEqual(snapshot.current.email, expectedCurrent.lowercased())
        XCTAssertEqual(Set(snapshot.accounts.map(\.email)), Set([expectedCurrent.lowercased(), expectedOther.lowercased()]))
        let evidence: [String: Any] = ["current_email": snapshot.current.email,
            "current_index": snapshot.current.index,
            "accounts": snapshot.accounts.map { ["email": $0.email, "index": $0.index] }]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        try data.write(to: traceURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: traceURL.path)
    }

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

    func testAttachApprovalPresentationUsesExactFileAndDraftFields() throws {
        let account = ComputerUseGmailAccountDirectory.Account(email: "current@example.com",
            displayName: "Current", index: 2)
        var job = try ComputerUseGmailJob(request: .init(to: ["alex@example.com", "sam@example.com"],
            cc: ["copy@example.com"], bcc: ["hidden@example.com"], subject: "Review",
            body: "Please review.", fileDescription: "deck", sendRequested: false,
            existingDraftURL: nil, account: account))
        XCTAssertNil(job.attachApprovalPresentation(), "A presentation requires a resolved attachment")
        try job.selectAttachment(.init(candidateID: "candidate-1", displayName: "Review.pptx", byteCount: 1_024))

        let presentation = try XCTUnwrap(job.attachApprovalPresentation())
        XCTAssertEqual(presentation.message, "Attach this file to the Gmail draft?")
        XCTAssertEqual(presentation.confirmLabel, "Attach file")
        XCTAssertEqual(presentation.details.map(\.label), ["File", "Size", "Destination", "To", "Subject", "CC", "BCC"])
        XCTAssertEqual(presentation.details.map(\.value), ["Review.pptx", "1024 bytes", "Gmail (current@example.com)",
            "alex@example.com, sam@example.com", "Review", "copy@example.com", "hidden@example.com"])
    }

    func testAttachApprovalPresentationRequiresAccountAndPrecedesSendApproval() throws {
        var job = try ComputerUseGmailJob(request: .init(to: ["alex@example.com"], cc: [], bcc: [],
            subject: "Review", body: "Please review.", fileDescription: "deck", sendRequested: false,
            existingDraftURL: nil))
        try job.selectAttachment(.init(candidateID: "candidate-1", displayName: "Review.pptx", byteCount: 1_024))
        XCTAssertNil(job.attachApprovalPresentation(), "Destination must be tied to a known Gmail account")

        var sendJob = try ComputerUseGmailJob(request: .init(to: ["alex@example.com"], cc: [], bcc: [],
            subject: "Review", body: "Please review.", fileDescription: "deck", sendRequested: true,
            existingDraftURL: nil, account: .init(email: "current@example.com", displayName: "Current", index: 2)))
        try sendJob.selectAttachment(.init(candidateID: "candidate-1", displayName: "Review.pptx", byteCount: 1_024))
        let attachmentPresentation = try XCTUnwrap(sendJob.attachApprovalPresentation())
        XCTAssertEqual(attachmentPresentation.message, "Attach this file to the Gmail draft?")
        XCTAssertEqual(attachmentPresentation.confirmLabel, "Attach file")
        XCTAssertEqual(attachmentPresentation.details.map(\.label), ["File", "Size", "Destination", "To", "Subject"])
        XCTAssertEqual(attachmentPresentation.details.map(\.value), ["Review.pptx", "1024 bytes", "Gmail (current@example.com)",
            "alex@example.com", "Review"])

        let sendPresentation = try XCTUnwrap(sendJob.sendApprovalPresentation())
        XCTAssertEqual(sendPresentation.message, "Send this email through Gmail?")
        XCTAssertEqual(sendPresentation.confirmLabel, "Send email")
    }

    func testAttachApprovalPresentationOmitsEmptyCopyFields() throws {
        var job = try ComputerUseGmailJob(request: .init(to: ["alex@example.com"], cc: [], bcc: [],
            subject: "Review", body: "Please review.", fileDescription: "deck", sendRequested: false,
            existingDraftURL: nil, account: .init(email: "current@example.com", displayName: "Current", index: 2)))
        try job.selectAttachment(.init(candidateID: "candidate-1", displayName: "Review.pptx", byteCount: 1_024))
        let presentation = try XCTUnwrap(job.attachApprovalPresentation())
        XCTAssertEqual(presentation.details.map(\.label), ["File", "Size", "Destination", "To", "Subject"])
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
