import Foundation
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseWebJobRequestTests: XCTestCase {
    func testEmailRoutesToGmailByDefaultAndAppleMailStaysExcluded() throws {
        guard case .gmail(let draft) = ComputerUseWebJobRequest.route(
            "Email Jordan a draft about the quarterly review; do not send it.") else {
            return XCTFail("Unqualified email work routes to Gmail on the web")
        }
        XCTAssertEqual(draft.originalRequest, "Email Jordan a draft about the quarterly review; do not send it.")
        XCTAssertFalse(draft.sendRequested)

        guard case .gmail(let send) = ComputerUseWebJobRequest.route(
            "Please send an email to jordan@example.com with the attached agenda.") else {
            return XCTFail("A literal send request routes to Gmail")
        }
        XCTAssertTrue(send.sendRequested)

        guard case .gmail(let negatedSend) = ComputerUseWebJobRequest.route(
            "Draft an email to Jordan; don't send it.") else {
            return XCTFail("An explicitly unsent email still routes to Gmail")
        }
        XCTAssertFalse(negatedSend.sendRequested)

        XCTAssertEqual(ComputerUseWebJobRequest.route("Email Jordan using Apple Mail."), .explicitAppleMail)
        XCTAssertEqual(ComputerUseWebJobRequest.route("Open Gmail."), .gmail(.init(originalRequest: "Open Gmail.", sendRequested: false)))
        XCTAssertEqual(ComputerUseWebJobRequest.route("Email alex@example.com with subject \"Apple Mail\"."),
            .gmail(.init(originalRequest: "Email alex@example.com with subject \"Apple Mail\".", sendRequested: false)))
        XCTAssertEqual(ComputerUseWebJobRequest.route("Draft an email in Gmail, not Apple Mail."),
            .gmail(.init(originalRequest: "Draft an email in Gmail, not Apple Mail.", sendRequested: false)))
    }

    func testNamedDriveAndDropboxFileOperationsRouteToTheirWebsites() throws {
        guard case .googleDriveUpload(let drive) = ComputerUseWebJobRequest.route(
            "Add the newest Board Review deck to Google Drive.") else {
            return XCTFail("Google Drive upload tasks route to the website")
        }
        XCTAssertEqual(drive.destination, .googleDrive)
        XCTAssertEqual(drive.originalRequest, "Add the newest Board Review deck to Google Drive.")

        guard case .dropboxUpload(let dropbox) = ComputerUseWebJobRequest.route(
            "Upload the selected spreadsheet to Dropbox.") else {
            return XCTFail("Dropbox upload tasks route to the website")
        }
        XCTAssertEqual(dropbox.destination, .dropbox)

        XCTAssertEqual(ComputerUseWebJobRequest.route("Save the file to Google Drive and Dropbox."),
            .ambiguousStorage([.googleDrive, .dropbox]))
        XCTAssertEqual(ComputerUseWebJobRequest.route("Upload \"Dropbox report.xlsx\" to Google Drive."),
            .googleDriveUpload(.init(originalRequest: "Upload \"Dropbox report.xlsx\" to Google Drive.", destination: .googleDrive)))

        let driveWithAccount = "Upload the selected report to Google Drive using spiderali97@gmail.com."
        XCTAssertEqual(ComputerUseWebJobRequest.route(driveWithAccount),
            .googleDriveUpload(.init(originalRequest: driveWithAccount, destination: .googleDrive)))
        let dropboxWithAccount = "Upload the selected report to Dropbox for spiderali97@gmail.com."
        XCTAssertEqual(ComputerUseWebJobRequest.route(dropboxWithAccount),
            .dropboxUpload(.init(originalRequest: dropboxWithAccount, destination: .dropbox)))
        XCTAssertEqual(ComputerUseWebJobRequest.route("Use Gmail to draft an email to spiderali97@gmail.com."),
            .gmail(.init(originalRequest: "Use Gmail to draft an email to spiderali97@gmail.com.", sendRequested: false)))
    }

    @MainActor
    func testSupportedWebNavigationURLsAreClosedToProviderRoots() {
        for raw in ["https://drive.google.com/drive/my-drive", "https://www.dropbox.com/home"] {
            XCTAssertTrue(ComputerUseDefaultBrowserSession.isSupportedWebNavigationURL(URL(string: raw)!))
        }
        for raw in [
            "https://example.com/drive/my-drive",
            "http://drive.google.com/drive/my-drive",
            "https://drive.google.com/drive/my-drive/other",
            "https://drive.google.com:443/drive/my-drive",
            "https://user@drive.google.com/drive/my-drive",
            "https://www.dropbox.com/home?preview=1",
        ] {
            XCTAssertFalse(ComputerUseDefaultBrowserSession.isSupportedWebNavigationURL(URL(string: raw)!))
        }
    }

    func testWebUploadRequestKeepsDestinationFolderSeparateFromSourceQuery() throws {
        let query = ComputerUseLocalFileCatalog.Query(fileKind: .spreadsheet,
            nameContains: "Board Review.xlsx", folderScope: .downloads)
        let drive = try ComputerUseWebUploadJob.Request(provider: .googleDrive,
            fileQuery: query, destinationFolder: "Quarterly Review")
        XCTAssertEqual(drive.fileQuery, query)
        XCTAssertEqual(drive.fileQuery.folderScope, .downloads)
        XCTAssertEqual(drive.destinationFolder, "Quarterly Review")
        XCTAssertEqual(drive.provider.homeURL.absoluteString, "https://drive.google.com/drive/my-drive")

        let dropbox = try ComputerUseWebUploadJob.Request(provider: .dropbox,
            fileQuery: query, destinationFolder: "Quarterly Review")
        XCTAssertEqual(dropbox.provider.homeURL.absoluteString, "https://www.dropbox.com/home")
        XCTAssertThrowsError(try ComputerUseWebUploadJob.Request(provider: .dropbox,
            fileQuery: query, destinationFolder: "/Users/example/Quarterly Review"),
            "A destination folder is a UI label, never a path")
    }

    func testDriveTitleSearchURLIsHostBuiltAndBoundToOneExactFilename() throws {
        let filename = "Remote Desktop Acceptance [fixture-1].pptx"
        let url = try XCTUnwrap(ComputerUseWebUploadJob.driveTitleSearchURL(filename: filename))
        XCTAssertEqual(url.host, "drive.google.com")
        XCTAssertEqual(url.path, "/drive/search")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "q", value: "title:\"\(filename)\"")])
        XCTAssertTrue(ComputerUseWebUploadJob.isDriveTitleSearchURL(url, filename: filename))
        XCTAssertFalse(ComputerUseWebUploadJob.isDriveTitleSearchURL(url, filename: "other.pptx"))
        XCTAssertNil(ComputerUseWebUploadJob.driveTitleSearchURL(filename: "contains \"quotes\".pptx"))
        XCTAssertFalse(ComputerUseWebUploadJob.isDriveTitleSearchURL(
            URL(string: "https://drive.google.com/drive/search?q=title%3A%22fixture-1.pptx%22&extra=1")!,
            filename: "fixture-1.pptx"))
    }

    @MainActor
    func testWebUploadNavigationTargetsAreBoundToTypedStage() throws {
        let home = URL(string: "https://drive.google.com/drive/my-drive")!
        let search = try XCTUnwrap(ComputerUseWebUploadJob.driveTitleSearchURL(filename: "Board Review.xlsx"))
        let provider = ComputerUseWebUploadJob.Provider.googleDrive

        XCTAssertTrue(ComputerUseDefaultBrowserSession.isSupportedWebUploadNavigationURL(
            home, stage: .home, provider: provider, filename: "Board Review.xlsx"))
        XCTAssertTrue(ComputerUseDefaultBrowserSession.isSupportedWebUploadNavigationURL(
            home, stage: .returnToRoot, provider: provider, filename: "Board Review.xlsx"))
        XCTAssertFalse(ComputerUseDefaultBrowserSession.isSupportedWebUploadNavigationURL(
            search, stage: .home, provider: provider, filename: "Board Review.xlsx"))
        XCTAssertFalse(ComputerUseDefaultBrowserSession.isSupportedWebUploadNavigationURL(
            home, stage: .collisionSearch, provider: provider, filename: "Board Review.xlsx"))
        XCTAssertTrue(ComputerUseDefaultBrowserSession.isSupportedWebUploadNavigationURL(
            search, stage: .collisionSearch, provider: provider, filename: "Board Review.xlsx"))
        XCTAssertTrue(ComputerUseDefaultBrowserSession.isSupportedWebUploadNavigationURL(
            search, stage: .finalSearch, provider: provider, filename: "Board Review.xlsx"))
        XCTAssertFalse(ComputerUseDefaultBrowserSession.isSupportedWebUploadNavigationURL(
            search, stage: .finalSearch, provider: .dropbox, filename: "Board Review.xlsx"))
        XCTAssertFalse(ComputerUseDefaultBrowserSession.isSupportedWebUploadNavigationURL(
            search, stage: .finalSearch, provider: provider, filename: "Other.xlsx"))
    }

    func testWebUploadFinalDetailsStagesStayOnExactSearchPage() {
        XCTAssertEqual(ComputerUseDefaultBrowserExecutor.WebUploadStage.checkCollisionSearch.pageTarget, .exactSearch)
        XCTAssertEqual(ComputerUseDefaultBrowserExecutor.WebUploadStage.checkFinalSearch.pageTarget, .exactSearch)
        XCTAssertEqual(ComputerUseDefaultBrowserExecutor.WebUploadStage.selectFinalResult.pageTarget, .exactSearch)
        XCTAssertEqual(ComputerUseDefaultBrowserExecutor.WebUploadStage.openFinalDetails.pageTarget, .exactSearch)
        XCTAssertEqual(ComputerUseDefaultBrowserExecutor.WebUploadStage.verifyFinalDetails.pageTarget, .exactSearch)
        XCTAssertEqual(ComputerUseDefaultBrowserExecutor.WebUploadStage.complete.pageTarget, .exactSearch)
        XCTAssertEqual(ComputerUseDefaultBrowserExecutor.WebUploadStage.navigateReturnToRoot.pageTarget, .home)
        XCTAssertEqual(ComputerUseDefaultBrowserExecutor.WebUploadStage.openUploaderMenu.pageTarget, .home)
    }

    func testDriveDetailsRequireExactSelectedFilenameSizeAndRootLocation() {
        let candidate = ComputerUseLocalFileCatalog.Candidate(id: "candidate-details",
            displayName: "Board Review.xlsx", contentTypeIdentifier: nil, fileExtension: "xlsx",
            byteCount: 8_192, modifiedAt: nil, createdAt: nil, addedToDirectoryAt: nil)
        let size = ByteCountFormatter.string(fromByteCount: candidate.byteCount, countStyle: .file)
        XCTAssertTrue(ComputerUseWebUploadJob.driveDetailsMatch(textValues: [
            candidate.displayName, "Size\u{00A0} \(size)", "Storage used\u{00A0} \(size)", "Location",
            "My Drive, show location in the list of files.",
        ], candidate: candidate))
        XCTAssertFalse(ComputerUseWebUploadJob.driveDetailsMatch(textValues: [
            candidate.displayName, "Size\u{00A0} 7 KB", "My Drive, show location in the list of files.",
        ], candidate: candidate))
        XCTAssertFalse(ComputerUseWebUploadJob.driveDetailsMatch(textValues: [
            candidate.displayName, "Size\u{00A0} \(size)", "Shared drive, show location in the list of files.",
        ], candidate: candidate))
        XCTAssertFalse(ComputerUseWebUploadJob.driveDetailsMatch(textValues: [
            candidate.displayName, candidate.displayName, "Size\u{00A0} \(size)",
            "My Drive, show location in the list of files.",
        ], candidate: candidate))
    }

    func testDriveDisplayedSizesMatchCalibratedBinaryKilobyteLabels() {
        XCTAssertEqual(ComputerUseWebUploadJob.displayedSize(byteCount: 100_000, provider: .googleDrive), "98 KB")
        XCTAssertEqual(ComputerUseWebUploadJob.displayedSize(byteCount: 8_406, provider: .googleDrive), "8 KB")
        XCTAssertEqual(ComputerUseWebUploadJob.displayedSize(byteCount: 100_000, provider: .dropbox),
                       Optional(ByteCountFormatter.string(fromByteCount: 100_000, countStyle: .file)),
                       "Dropbox formatting remains unchanged until calibrated")

        let candidate = ComputerUseLocalFileCatalog.Candidate(id: "candidate-100kb",
            displayName: "Calibration.pptx", contentTypeIdentifier: nil, fileExtension: "pptx",
            byteCount: 100_000, modifiedAt: nil, createdAt: nil, addedToDirectoryAt: nil)
        let row = ComputerUseWebUploadJob.ListingRow(rowID: "drive-row-calibration", cellLabels: [
            candidate.displayName, "me", "Today", "My Drive", "Size: 98 KB Storage used: 98 KB",
        ])
        XCTAssertEqual(ComputerUseWebUploadJob.listingEvidence(rows: [row], candidate: candidate,
            progress: .complete, pageIsComplete: true,
            expectedLocationLabel: ComputerUseWebUploadJob.driveRootLocationLabel), .complete)

        let decimalRow = ComputerUseWebUploadJob.ListingRow(rowID: "drive-row-decimal", cellLabels: [
            candidate.displayName, "me", "Today", "My Drive", "Size: 100 KB Storage used: 100 KB",
        ])
        XCTAssertEqual(ComputerUseWebUploadJob.listingEvidence(rows: [decimalRow], candidate: candidate,
            progress: .complete, pageIsComplete: true,
            expectedLocationLabel: ComputerUseWebUploadJob.driveRootLocationLabel), .mismatch)

        XCTAssertNil(ComputerUseWebUploadJob.displayedSize(byteCount: 1_048_577, provider: .googleDrive),
                     "Drive MB labels remain unsupported until calibrated")
        let megabyteCandidate = ComputerUseLocalFileCatalog.Candidate(id: "candidate-large",
            displayName: "Large.pptx", contentTypeIdentifier: nil, fileExtension: "pptx",
            byteCount: 1_048_577, modifiedAt: nil, createdAt: nil, addedToDirectoryAt: nil)
        let megabyteRow = ComputerUseWebUploadJob.ListingRow(rowID: "drive-row-large", cellLabels: [
            megabyteCandidate.displayName, "me", "Today", "My Drive", "Size: 1 MB Storage used: 1 MB",
        ])
        XCTAssertEqual(ComputerUseWebUploadJob.listingEvidence(rows: [megabyteRow], candidate: megabyteCandidate,
            progress: .complete, pageIsComplete: true,
            expectedLocationLabel: ComputerUseWebUploadJob.driveRootLocationLabel), .mismatch)
    }

    func testWebUploadEffectLatchesPreventReplayingAnUncertainDispatch() {
        var latch = ComputerUseWebUploadJob.DispatchLatch()
        XCTAssertTrue(latch.beginSiteUpload())
        XCTAssertFalse(latch.beginSiteUpload(), "An uncertain website upload must be verified, never redispatched")
        XCTAssertTrue(latch.siteUploadAttempted)
        XCTAssertFalse(latch.nativeOpenAttempted)

        XCTAssertTrue(latch.beginNativeOpen())
        XCTAssertFalse(latch.beginNativeOpen(), "An uncertain native Open must not be replayed")
        XCTAssertTrue(latch.siteUploadAttempted)
        XCTAssertTrue(latch.nativeOpenAttempted)
    }

    func testWebUploadUsesBoundUserFileChoiceBeforeAmbiguousAutomaticSelection() {
        let automatic = ComputerUseLocalFileCatalog.Candidate(id: "automatic-choice",
            displayName: "Quarterly Metrics.xlsx", contentTypeIdentifier: nil, fileExtension: "xlsx",
            byteCount: 8_192, modifiedAt: nil, createdAt: nil, addedToDirectoryAt: nil)
        let selected = ComputerUseLocalFileCatalog.Candidate(id: "user-choice",
            displayName: "Quarterly Metrics final.xlsx", contentTypeIdentifier: nil, fileExtension: "xlsx",
            byteCount: 9_216, modifiedAt: nil, createdAt: nil, addedToDirectoryAt: nil)

        XCTAssertEqual(ComputerUseWebUploadJob.selectedUploadCandidate(
            visibleCandidates: [automatic, selected], automaticCandidateID: nil,
            userSelectedCandidateID: selected.id)?.id, selected.id,
            "A prior user choice remains authoritative when the original query is still ambiguous")
        XCTAssertNil(ComputerUseWebUploadJob.selectedUploadCandidate(
            visibleCandidates: [automatic, selected], automaticCandidateID: automatic.id,
            userSelectedCandidateID: "stale-choice"),
            "A user choice missing from the current verified page must stop instead of falling back")
        XCTAssertEqual(ComputerUseWebUploadJob.selectedUploadCandidate(
            visibleCandidates: [automatic, selected], automaticCandidateID: automatic.id,
            userSelectedCandidateID: nil)?.id, automatic.id,
            "Automatic selection remains unchanged when no explicit user choice exists")
    }

    func testWebUploadExtractionResolvesQuotedSourceAndDestinationLiterals() throws {
        let original = "Upload the \"Quarterly Metrics.xlsx\" file to Google Drive in the \"Archive 2026\" folder."
        let extractor = try makeExtractor(transport: WebJobTransport(reply: try envelope("{}")))
        let request = try extractor.makeUploadRequest(originalRequest: original)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let schema = try XCTUnwrap(json["response_format"] as? [String: Any])
        let schemaBody = try XCTUnwrap(schema["json_schema"] as? [String: Any])
        let root = try XCTUnwrap(schemaBody["schema"] as? [String: Any])
        let properties = try XCTUnwrap(root["properties"] as? [String: Any])
        let folderSchema = try XCTUnwrap(properties["destination_folder"] as? [String: Any])
        XCTAssertTrue((folderSchema["anyOf"] as? [[String: Any]])?.contains(where: {
            ($0["enum"] as? [String])?.contains("q1") == true
        }) == true)
        XCTAssertFalse((messages.first?["content"] as? String ?? "").contains("full local path"))

        let content = #"{"file_description":{"description":"quarterly metrics workbook","file_kind":"spreadsheet","name_contains":"q0","folder_scope":"downloads","date_field":"none","direction":"none"},"destination_folder":"q1"}"#
        let extraction = try ComputerUseWebJobContentExtractor.decodeUpload(content, originalRequest: original)
        XCTAssertEqual(extraction.fileQuery.nameContains, "Quarterly Metrics.xlsx")
        XCTAssertEqual(extraction.fileQuery.fileKind, .spreadsheet)
        XCTAssertEqual(extraction.destinationFolder, "Archive 2026")
    }

    func testWebUploadCompletionRequiresOneSameRowNameSizeAndFinishedStatus() {
        let candidate = ComputerUseLocalFileCatalog.Candidate(id: "candidate-1",
            displayName: "Board Review.xlsx", contentTypeIdentifier: nil, fileExtension: "xlsx",
            byteCount: 8_192, modifiedAt: nil, createdAt: nil, addedToDirectoryAt: nil)
        let displayedSize = ByteCountFormatter.string(fromByteCount: candidate.byteCount, countStyle: .file)
        let observedSizeCell = "Size: \(displayedSize) Storage used: \(displayedSize)"
        func row(_ id: String, _ cells: [String]) -> ComputerUseWebUploadJob.ListingRow {
            .init(rowID: id, cellLabels: cells)
        }
        func evidence(_ rows: [ComputerUseWebUploadJob.ListingRow],
                      progress: ComputerUseWebUploadJob.UploadProgress = .complete,
                      pageIsComplete: Bool = true,
                      expectedLocation: String? = nil) -> ComputerUseWebUploadJob.ListingEvidence {
            ComputerUseWebUploadJob.listingEvidence(rows: rows, candidate: candidate,
                progress: progress, pageIsComplete: pageIsComplete,
                expectedLocationLabel: expectedLocation)
        }

        XCTAssertEqual(evidence([row("drive-row-1", [
            "Board Review.xlsx", "me", "Today", observedSizeCell,
        ])]), .complete)
        XCTAssertEqual(evidence([row("drive-row-root", [
            "Board Review.xlsx", "me", "Today", "My Drive", observedSizeCell,
        ])], expectedLocation: "My Drive"), .complete)
        XCTAssertNotEqual(evidence([row("drive-row-other-location", [
            "Board Review.xlsx", "me", "Today", "Shared drive", observedSizeCell,
        ])], expectedLocation: "My Drive"), .complete)
        XCTAssertNotEqual(evidence([row("drive-row-wrong-size", [
            "Board Review.xlsx", "me", "Today", "Size: 7 KB Storage used: 7 KB",
        ])]), .complete)
        XCTAssertNotEqual(evidence([
            row("drive-row-name", ["Board Review.xlsx", "me", "Today"]),
            row("drive-row-size", [observedSizeCell]),
        ]), .complete, "Name and size from separate rows must not combine")
        XCTAssertNotEqual(evidence([row("drive-row-pending", [
            "Board Review.xlsx", "me", "Today", displayedSize,
        ])], progress: .inProgress), .complete)
        XCTAssertNotEqual(evidence([
            row("drive-row-1", ["Board Review.xlsx", "me", "Today", observedSizeCell]),
            row("drive-row-2", ["Board Review.xlsx", "me", "Yesterday", observedSizeCell]),
        ]), .complete, "Duplicate exact-name rows are ambiguous")
        XCTAssertNotEqual(evidence([row("drive-row-incomplete-page", [
            "Board Review.xlsx", "me", "Today", observedSizeCell,
        ])], pageIsComplete: false), .complete, "A truncated listing cannot establish uniqueness")

        let rootRowWithoutSize = row("drive-row-details", ["Board Review.xlsx", "me", "Today", "My Drive"])
        let details = ["Board Review.xlsx", "Size\u{00A0} \(displayedSize)",
            "Storage used\u{00A0} \(displayedSize)", "Location",
            "My Drive, show location in the list of files."]
        XCTAssertTrue(ComputerUseWebUploadJob.verifiesDriveCompletion(rows: [row("drive-row-sized", [
            "Board Review.xlsx", "me", "Today", "My Drive", observedSizeCell,
        ])], candidate: candidate, progress: .complete, pageIsComplete: true, detailsTextValues: []),
            "A unique same-row size is sufficient when the result table exposes it")
        XCTAssertTrue(ComputerUseWebUploadJob.verifiesDriveCompletion(rows: [rootRowWithoutSize],
            candidate: candidate, progress: .complete, pageIsComplete: true, detailsTextValues: details),
            "A unique bound row can use its selected Details size when the listing omits size")
        XCTAssertFalse(ComputerUseWebUploadJob.verifiesDriveCompletion(rows: [rootRowWithoutSize,
            row("drive-row-duplicate-other-location", ["Board Review.xlsx", "Shared drive"])],
            candidate: candidate, progress: .complete, pageIsComplete: true, detailsTextValues: details),
            "A second exact-name row is ambiguous even when it is outside My Drive")
        XCTAssertFalse(ComputerUseWebUploadJob.verifiesDriveCompletion(rows: [rootRowWithoutSize],
            candidate: candidate, progress: .inProgress, pageIsComplete: true, detailsTextValues: details))
    }

    func testNonwebJobsAndPausedLocalSyncRemainUnrouted() {
        XCTAssertEqual(ComputerUseWebJobRequest.route("Search the web for email providers."), .none)
        XCTAssertEqual(ComputerUseWebJobRequest.route("Copy the workbook to iCloud Drive."), .none)
        XCTAssertEqual(ComputerUseWebJobRequest.route("Open my Documents folder."), .none)
        XCTAssertEqual(ComputerUseWebJobRequest.route(" \n "), .none)
        XCTAssertEqual(ComputerUseWebJobRequest.route(String(repeating: "x", count: 32 * 1_024 + 1)), .none)
    }

    func testRecipientResolutionUsesLiteralSelfAccountOrContactsOnly() async throws {
        let literal = try await ComputerUseWebJobRequest.resolveRecipient(
            in: #"Draft an email to jordan@example.com with subject "send to hidden@example.com" and body "Contact other@example.com.""#,
            trustedAccountControlLabel: nil)
        XCTAssertEqual(literal, .addresses(["jordan@example.com"]))

        let selfRecipient = try await ComputerUseWebJobRequest.resolveRecipient(
            in: "Address it to my own email address for the signed-in account. Subject: Review",
            trustedAccountControlLabel: "Google Account: Example User (account@example.com), Google membership")
        XCTAssertEqual(selfRecipient, .addresses(["account@example.com"]))

        let fullGmailPrompt = try await ComputerUseWebJobRequest.resolveRecipient(
            in: "Use the Gmail compose opened by the host; do not create another compose. Address it to my own email address for the signed-in account. Use the exact subject \"Remote Desktop acceptance [token]\" and exact body \"Please review the attached file.\" Attach the file named \"file.xlsx\" from Downloads. Leave the draft open for review and never send it.",
            trustedAccountControlLabel: "Google Account: Example User (account@example.com), Google membership")
        XCTAssertEqual(fullGmailPrompt, .addresses(["account@example.com"]))

        let ungroundedSelf = try await ComputerUseWebJobRequest.resolveRecipient(
            in: "Email me the review", trustedAccountControlLabel: nil)
        XCTAssertEqual(ungroundedSelf, .clarification("Which email address should I use for your account?"))

        let contact = try await ComputerUseWebJobRequest.resolveRecipient(
            in: "Draft an email to Jordan about Friday",
            trustedAccountControlLabel: nil,
            lookup: { name in [ComputerUseMailRecipients.Match(name: name, address: "jordan@example.com")] })
        XCTAssertEqual(contact, .addresses(["jordan@example.com"]))

        let ambiguous = try await ComputerUseWebJobRequest.resolveRecipient(
            in: "Draft an email to Jordan about Friday",
            trustedAccountControlLabel: nil,
            lookup: { name in [
                ComputerUseMailRecipients.Match(name: name, address: "jordan.one@example.com"),
                ComputerUseMailRecipients.Match(name: name, address: "jordan.two@example.com"),
            ] })
        guard case .choose(name: "Jordan", matches: let matches) = ambiguous else {
            return XCTFail("Ambiguous Contacts matches require an explicit choice")
        }
        XCTAssertEqual(matches.map(\.address), ["jordan.one@example.com", "jordan.two@example.com"])
    }

    func testAmbiguousChoiceDoesNotCoverAdditionalRecipientReference() async throws {
        let request = "Draft an email to Jordan, Alex"
        let resolution = try await ComputerUseWebJobRequest.resolveRecipient(
            in: request, trustedAccountControlLabel: nil,
            lookup: { _ in [
                ComputerUseMailRecipients.Match(name: "Jordan Lee", address: "jordan.one@example.com"),
                ComputerUseMailRecipients.Match(name: "Jordan Lee", address: "jordan.two@example.com"),
            ] })
        XCTAssertEqual(resolution, .clarification(
            "Please provide the exact email addresses for all recipients so I can avoid choosing the wrong person."),
            "A choice for one entry cannot silently replace a mixed-recipient request")
    }

    func testExtractionRequestExposesOnlyThreeContentFieldsAndPreservesPrompt() throws {
        let prompt = "Draft to Jordan at jordan@example.com. Subject: Board Review. Body: The meeting is Friday. Attach the latest deck."
        let clarifications = [["question": "Which deck?", "answer": "The Board Review deck."]]
        let extractor = try makeExtractor(transport: WebJobTransport(reply: Data()))
        let request = try extractor.makeRequest(originalRequest: prompt, clarifications: clarifications)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "fixture-local-model")
        XCTAssertEqual(body["temperature"] as? Double, 0)
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        let chatTemplateArguments = try XCTUnwrap(body["chat_template_kwargs"] as? [String: Any])
        XCTAssertEqual(chatTemplateArguments["enable_thinking"] as? Bool, false)

        let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
        let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["subject", "body", "file_description"])
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), ["subject", "body", "file_description"])
        let fileDescriptionSchema = try XCTUnwrap(properties["file_description"] as? [String: Any])
        let fileDescriptionBranches = try XCTUnwrap(fileDescriptionSchema["anyOf"] as? [[String: Any]])
        XCTAssertTrue(fileDescriptionBranches.contains { $0["type"] as? String == "null" })
        let fileObject = try XCTUnwrap(fileDescriptionBranches.first { $0["type"] as? String == "object" })
        XCTAssertEqual(fileObject["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set((fileObject["properties"] as? [String: Any] ?? [:]).keys),
            ["description", "file_kind", "name_contains", "folder_scope", "date_field", "direction"])

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertFalse(system.isEmpty)
        let requestContext = try XCTUnwrap(messages.last?["content"] as? String)
        let context = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(requestContext.utf8)) as? [String: Any])
        XCTAssertEqual(context["original_request"] as? String, prompt)
        XCTAssertEqual(context["clarifications"] as? [[String: String]], clarifications)
        XCTAssertFalse(properties.keys.contains("to"))
        XCTAssertFalse(properties.keys.contains("path"))
        XCTAssertFalse(properties.keys.contains("sha256"))
    }

    func testExtractionDecoderPreservesValuesAndRejectsMalformedOrHostFields() throws {
        let valid = #"{"subject":"Board Review","body":"The meeting is Friday.\nThanks, Jordan","file_description":{"description":"the latest Board Review deck","file_kind":"presentation","name_contains":"Board Review","folder_scope":"downloads","date_field":"modifiedAt","direction":"descending"}}"#
        XCTAssertEqual(try ComputerUseWebJobContentExtractor.decode(valid), .init(
            subject: "Board Review", body: "The meeting is Friday.\nThanks, Jordan",
            fileDescription: "the latest Board Review deck",
            fileQuery: .init(fileKind: .presentation,
                sort: .init(field: .modifiedAt, direction: .descending),
                nameContains: "Board Review", folderScope: .downloads)))
        let exactFilename = #"{"subject":"","body":"","file_description":{"description":"the file named BoardReview Final.pptx","file_kind":"presentation","name_contains":"BoardReview Final.pptx","folder_scope":"documents","date_field":"none","direction":"none"}}"#
        XCTAssertEqual(try ComputerUseWebJobContentExtractor.decode(exactFilename), .init(
            subject: "", body: "", fileDescription: "the file named BoardReview Final.pptx",
            fileQuery: .init(fileKind: .presentation, nameContains: "BoardReview Final.pptx", folderScope: .documents)))
        XCTAssertEqual(try ComputerUseWebJobContentExtractor.decode(
            #"{"subject":"","body":"","file_description":null}"#),
            .init(subject: "", body: "", fileDescription: ""))

        let invalid = [
            #"{"subject":"x","body":"y","file_description":null,"recipient":"jordan@example.com"}"#,
            #"{"subject":"x","subject":"y","body":"z","file_description":""}"#,
            #"{"subject":"x","body":"y","file_description":{"description":"latest deck","file_kind":"presentation","name_contains":"x","folder_scope":"downloads","date_field":"modifiedAt","direction":"descending","source_path":"/Users/me/secret.pptx"}}"#,
            #"{"subject":"x","body":"y","file_description":{"description":"/Users/me/secret.pptx","file_kind":"presentation","name_contains":"x","folder_scope":"downloads","date_field":"none","direction":"none"}}"#,
            #"{"subject":"x","body":"y","file_description":{"description":"latest deck","file_kind":"presentation","name_contains":"https://example.com/file","folder_scope":"downloads","date_field":"none","direction":"none"}}"#,
            #"{"subject":"x","body":"y","file_description":{"description":"latest deck","file_kind":"presentation","name_contains":"aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899","folder_scope":"downloads","date_field":"none","direction":"none"}}"#,
            #"{"subject":"x","body":"y","file_description":{"description":"latest deck","file_kind":"unknown","name_contains":"x","folder_scope":"downloads","date_field":"none","direction":"none"}}"#,
            #"{"subject":"x","body":"y","file_description":{"description":"latest deck","file_kind":"presentation","name_contains":"x","folder_scope":"downloads","date_field":"none","direction":"descending"}}"#,
            #"{"subject":"x","body":"y","file_description":{"description":"latest deck","description":"other","file_kind":"presentation","name_contains":"x","folder_scope":"downloads","date_field":"none","direction":"none"}}"#,
            #"{"subject":"x\ny","body":"y","file_description":"z"}"#,
            #"{"subject":"x","body":"\#(String(repeating: "é", count: 4_001))","file_description":null}"#,
            "not JSON",
        ]
        for content in invalid {
            XCTAssertThrowsError(try ComputerUseWebJobContentExtractor.decode(content))
        }
    }

    func testLiteralFilenameExtensionOverridesCoarseFileKindWithoutChangingQueryAuthority() throws {
        func decode(_ fileName: String, kind: String) throws -> ComputerUseLocalFileCatalog.Query? {
            let object: [String: Any] = [
                "subject": "", "body": "",
                "file_description": [
                    "description": "the file named \(fileName)",
                    "file_kind": kind,
                    "name_contains": fileName,
                    "folder_scope": "downloads",
                    "date_field": "modifiedAt",
                    "direction": "descending",
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try ComputerUseWebJobContentExtractor.decode(String(decoding: data, as: UTF8.self)).fileQuery
        }

        let spreadsheet = try XCTUnwrap(decode("Gmail Acceptance - Quarterly Metrics.XLSX", kind: "document"))
        XCTAssertEqual(spreadsheet.fileKind, .spreadsheet)
        XCTAssertEqual(spreadsheet.nameContains, "Gmail Acceptance - Quarterly Metrics.XLSX")
        XCTAssertEqual(spreadsheet.folderScope, .downloads)
        XCTAssertEqual(spreadsheet.sort, .init(field: .modifiedAt, direction: .descending))

        XCTAssertEqual(try decode("Quarterly Metrics.pptx", kind: "document")?.fileKind, .presentation)
        XCTAssertEqual(try decode("Quarterly Metrics.pdf", kind: "spreadsheet")?.fileKind, .document)
        XCTAssertEqual(try decode("Quarterly Metrics.unknown", kind: "presentation")?.fileKind, .presentation)
        XCTAssertEqual(try decode("Quarterly Metrics", kind: "spreadsheet")?.fileKind, .spreadsheet)

        XCTAssertThrowsError(try decode("/Users/example/Downloads/Quarterly Metrics.xlsx", kind: "document"),
            "A recognized suffix must not make a path-like value acceptable")
    }

    func testExtractorUsesOnlyLocalStrictTextProposal() async throws {
        let responseContent = #"{"subject":"Board Review","body":"The meeting is Friday.","file_description":{"description":"the latest Board Review deck","file_kind":"presentation","name_contains":"Board Review","folder_scope":"downloads","date_field":"modifiedAt","direction":"descending"}}"#
        let transport = WebJobTransport(reply: try envelope(responseContent))
        let extractor = try makeExtractor(transport: transport)
        let result = try await extractor.propose(originalRequest: "Email Jordan about Friday and attach the latest Board Review deck.")
        XCTAssertEqual(result, .init(subject: "Board Review", body: "The meeting is Friday.",
            fileDescription: "the latest Board Review deck", fileQuery: .init(fileKind: .presentation,
                sort: .init(field: .modifiedAt, direction: .descending), nameContains: "Board Review",
                folderScope: .downloads)))
        let lastRequest = await transport.lastRequest()
        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.url?.host, "127.0.0.1")
    }

    func testExtractorResolvesModelSelectedQuotedLiteralReferencesExactly() async throws {
        let subject = "Rëveiw [typo-λ]"
        let body = "Line one  with exact spacing; café."
        let filename = "Δonnées Qtr typo.xlsx"
        let prompt = "Draft an email to Jordan with subject \"\(subject)\" and body “\(body)”. Attach the file named \"\(filename)\" from Downloads."
        let response: [String: Any] = [
            "subject": ["literal_id": "q0"],
            "body": ["literal_id": "q1"],
            "file_description": [
                "description": "the file named", "file_kind": "spreadsheet",
                "name_contains": ["literal_id": "q2"], "folder_scope": "downloads",
                "date_field": "none", "direction": "none",
            ],
        ]
        let responseData = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        let transport = WebJobTransport(reply: try envelope(String(decoding: responseData, as: UTF8.self)))
        let extractor = try makeExtractor(transport: transport)

        let result = try await extractor.propose(originalRequest: prompt)
        XCTAssertEqual(result.subject, subject)
        XCTAssertEqual(result.body, body)
        XCTAssertEqual(result.fileQuery?.nameContains, filename)
        XCTAssertEqual(result.fileQuery?.fileKind, .spreadsheet)

        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        let bodyObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(bodyObject["messages"] as? [[String: Any]])
        let contextString = try XCTUnwrap(messages.last?["content"] as? String)
        let context = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contextString.utf8)) as? [String: Any])
        XCTAssertEqual(context["literal_payloads"] as? [String: String],
            ["q0": subject, "q1": body, "q2": filename])
    }

    func testExtractorUsesLiteralReferencesAndExactSourceTextObjectsWhenQuotesExist() async throws {
        let subject = "Rëview [typo-λ]"
        let filename = "Δonnées Qtr typo.xlsx"
        let body = "Please review the figures."
        let prompt = "Draft an email with subject \"\(subject)\" and body \(body). Attach \"\(filename)\"."
        let response: [String: Any] = [
            "subject": "q0",
            "body": ["source_text": body],
            "file_description": [
                "description": "the requested file", "file_kind": "spreadsheet",
                "name_contains": "q1", "folder_scope": "downloads",
                "date_field": "none", "direction": "none",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        let extractor = try makeExtractor(transport: WebJobTransport(reply: try envelope(String(decoding: data, as: UTF8.self))))
        let result = try await extractor.propose(originalRequest: prompt)
        XCTAssertEqual(result.subject, subject)
        XCTAssertEqual(result.body, body)
        XCTAssertEqual(result.fileQuery?.nameContains, filename)

        let request = try XCTUnwrap(try extractor.makeRequest(originalRequest: prompt).httpBody)
        let requestObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: request) as? [String: Any])
        let format = try XCTUnwrap(requestObject["response_format"] as? [String: Any])
        let schemaContainer = try XCTUnwrap(format["json_schema"] as? [String: Any])
        let schema = try XCTUnwrap(schemaContainer["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        for field in ["subject", "body"] {
            let fieldSchema = try XCTUnwrap(properties[field] as? [String: Any])
            let alternatives = try XCTUnwrap(fieldSchema["anyOf"] as? [[String: Any]])
            XCTAssertEqual(alternatives.count, 2)
            XCTAssertEqual(alternatives[0]["type"] as? String, "string")
            XCTAssertEqual(alternatives[0]["enum"] as? [String], ["", "q0", "q1"])
            XCTAssertEqual(alternatives[1]["type"] as? String, "object")
            let sourceProperties = try XCTUnwrap(alternatives[1]["properties"] as? [String: Any])
            XCTAssertEqual(Set(sourceProperties.keys), ["source_text"])
            XCTAssertEqual(alternatives[1]["additionalProperties"] as? Bool, false)
        }
        let fileDescriptionSchema = try XCTUnwrap(properties["file_description"] as? [String: Any])
        let fileDescriptionAlternatives = try XCTUnwrap(fileDescriptionSchema["anyOf"] as? [[String: Any]])
        let fileDescriptionObject = try XCTUnwrap(fileDescriptionAlternatives.first { $0["type"] as? String == "object" })
        let fileDescriptionProperties = try XCTUnwrap(fileDescriptionObject["properties"] as? [String: Any])
        let nameContainsSchema = try XCTUnwrap(fileDescriptionProperties["name_contains"] as? [String: Any])
        let nameContainsAlternatives = try XCTUnwrap(nameContainsSchema["anyOf"] as? [[String: Any]])
        XCTAssertEqual(nameContainsAlternatives[0]["enum"] as? [String], ["", "q0", "q1"])
        XCTAssertEqual(nameContainsAlternatives[1]["type"] as? String, "object")

        for invalid in [
            #"{"subject":"unknown-q","body":{"source_text":"Please review the figures."},"file_description":{"description":"requested file","file_kind":"spreadsheet","name_contains":"q1","folder_scope":"downloads","date_field":"none","direction":"none"}}"#,
            #"{"subject":"Rëview [typo-λ]","body":{"source_text":"Please review the figures."},"file_description":{"description":"requested file","file_kind":"spreadsheet","name_contains":"q1","folder_scope":"downloads","date_field":"none","direction":"none"}}"#,
            #"{"subject":{"literal_id":"q9"},"body":{"source_text":"Please review the figures."},"file_description":{"description":"requested file","file_kind":"spreadsheet","name_contains":{"literal_id":"q1"},"folder_scope":"downloads","date_field":"none","direction":"none"}}"#,
            #"{"subject":{"literal_id":"q0"},"body":{"source_text":"Please review the figures altered."},"file_description":{"description":"requested file","file_kind":"spreadsheet","name_contains":{"literal_id":"q1"},"folder_scope":"downloads","date_field":"none","direction":"none"}}"#,
            #"{"subject":{"literal_id":"q0"},"body":{"source_text":"Rëview [typo"},"file_description":{"description":"requested file","file_kind":"spreadsheet","name_contains":{"literal_id":"q1"},"folder_scope":"downloads","date_field":"none","direction":"none"}}"#,
            #"{"subject":{"literal_id":"q0"},"body":{"source_text":"Please review the figures."},"file_description":{"description":"requested file","file_kind":"spreadsheet","name_contains":{"literal_id":"q2"},"folder_scope":"downloads","date_field":"none","direction":"none"}}"#,
        ] {
            XCTAssertThrowsError(try ComputerUseWebJobContentExtractor.decode(invalid, originalRequest: prompt),
                "A reference or source string outside this exact task's inventory must be rejected")
        }
    }

    func testExtractorRejectsMutatedQuotedTextAndUnknownLiteralReference() async throws {
        let exactSubject = "Quarterly Review [147b3ba460c143a6aedde7ba27f52f57]"
        let prompt = "Draft an email with the exact subject \"\(exactSubject)\" and body “Review the figures.”"
        for proposal in [
            #"{"subject":"Quarterly Review [147b3ba460c143a6aedde7ba27f52f]","body":{"literal_id":"q1"},"file_description":null}"#,
            #"{"subject":{"literal_id":"q9"},"body":{"literal_id":"q1"},"file_description":null}"#,
        ] {
            let extractor = try makeExtractor(transport: WebJobTransport(reply: try envelope(proposal)))
            do {
                _ = try await extractor.propose(originalRequest: prompt)
                XCTFail("Only an exact source-backed literal reference may supply quoted field text")
            } catch let error as ComputerUseWebJobContentExtractor.Error {
                XCTAssertEqual(error, .invalidResponse)
            }
        }
    }

    func testExtractorLiteralInventoryIncludesAcceptedClarificationsAndRejectsAmbiguousQuotes() async throws {
        let extractor = try makeExtractor(transport: WebJobTransport(reply: try envelope(
            #"{"subject":{"literal_id":"q1"},"body":{"literal_id":"q0"},"file_description":null}"#)))
        let result = try await extractor.propose(originalRequest: "Draft about \"Quarterly\".",
            clarifications: [["question": "What subject?", "answer": "Use “Rëview” exactly."]])
        XCTAssertEqual(result.subject, "Rëview")
        XCTAssertEqual(result.body, "Quarterly")

        XCTAssertThrowsError(try extractor.makeRequest(originalRequest: "Draft with an unmatched \"literal.")) { error in
            XCTAssertEqual(error as? ComputerUseWebJobContentExtractor.Error, .invalidInput)
        }
        let tooManyQuotedSpans = String(repeating: "\"x\" ", count: 33)
        XCTAssertThrowsError(try extractor.makeRequest(originalRequest: tooManyQuotedSpans)) { error in
            XCTAssertEqual(error as? ComputerUseWebJobContentExtractor.Error, .invalidInput)
        }
        XCTAssertThrowsError(try extractor.makeRequest(originalRequest: #"Draft with an ambiguous escaped quote \" inside."#)) { error in
            XCTAssertEqual(error as? ComputerUseWebJobContentExtractor.Error, .invalidInput)
        }
    }

    func testOptInProductionGmailContentExtractionExchangeCapture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_GMAIL_CONTENT_EXTRACTOR_CAPTURE"] == "1" else {
            throw XCTSkip("Opt-in production native-text extraction capture; no browser actions")
        }
        let expectedURL = URL(fileURLWithPath: try XCTUnwrap(environment["GMAIL_CONTENT_EXTRACTOR_EXPECTED_PATH"]))
        let outputURL = URL(fileURLWithPath: try XCTUnwrap(environment["GMAIL_CONTENT_EXTRACTOR_EXCHANGE_PATH"]))
        let expected = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as? [String: Any])
        XCTAssertEqual(expected["job"] as? String, "gmail")
        let prompt = try XCTUnwrap(expected["prompt"] as? String)
        XCTAssertTrue(prompt.contains("Remote Desktop acceptance ["))

        guard let receipt = await ComputerUseInstaller.nativeText().currentInstallation() else {
            throw XCTSkip("The verified native-text runtime is not installed")
        }
        let runtimeDirectory = try await OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: .main)
        let inputs = try OSAtlasRuntimeInputResolver(manifest: .nativeTextV2).resolveNativeText(
            receipt: receipt, runtimeDirectoryURL: runtimeDirectory, enclosingBundleURL: Bundle.main.bundleURL)
        let runtime = OSAtlasLlamaRuntime()
        let extraction: ComputerUseWebJobContentExtractor.Extraction
        do {
            let endpoint = try await runtime.activateNativeText(inputs)
            extraction = try await runtime.extractWebJobContent(endpoint: endpoint, originalRequest: prompt,
                inspectExchange: { requestBody, response in
                    guard let requestText = String(data: requestBody, encoding: .utf8),
                          let responseText = String(data: response, encoding: .utf8),
                          let capture = try? JSONSerialization.data(withJSONObject: [
                            "request_body": requestText, "response": responseText,
                          ], options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
                    try? capture.write(to: outputURL, options: .atomic)
                })
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            throw error
        }

        XCTAssertEqual(extraction.subject, expected["subject"] as? String)
        XCTAssertEqual(extraction.body, expected["body"] as? String)
        XCTAssertEqual(extraction.fileQuery?.nameContains, expected["attachment_name"] as? String)

        let captureData = try Data(contentsOf: outputURL)
        let capture = try XCTUnwrap(try JSONSerialization.jsonObject(with: captureData) as? [String: String])
        XCTAssertEqual(Set(capture.keys), ["request_body", "response"])
        XCTAssertTrue(try XCTUnwrap(capture["request_body"]).contains("Remote Desktop acceptance ["))
    }

    private func makeExtractor(transport: any ComputerUseTextModelTransport) throws -> ComputerUseWebJobContentExtractor {
        .init(connection: try ComputerUseTextModelConnection(
            baseURL: URL(string: "http://127.0.0.1:49123")!,
            bearerToken: "fixture-web-job-extractor-token",
            modelAlias: "fixture-local-model"), transport: transport)
    }

    private func envelope(_ content: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": "fixture-local-model", "choices": [[
            "finish_reason": "stop", "message": ["role": "assistant", "content": content],
        ]]])
    }
}

private actor WebJobTransport: ComputerUseTextModelTransport {
    private let reply: Data
    private var request: URLRequest?

    init(reply: Data) { self.reply = reply }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int { 1_000 }
    func complete(request: URLRequest) async throws -> Data {
        self.request = request
        return reply
    }
    func lastRequest() -> URLRequest? { request }
}
