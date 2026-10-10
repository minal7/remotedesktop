import Foundation

/// Typed host-owned data and completion evidence for one web storage upload.
/// This value never contains a local path or authorizes an upload action.
struct ComputerUseWebUploadJob: Sendable {
    struct DispatchLatch: Equatable, Sendable {
        private(set) var siteUploadAttempted = false
        private(set) var nativeOpenAttempted = false

        mutating func beginSiteUpload() -> Bool {
            guard !siteUploadAttempted else { return false }
            siteUploadAttempted = true
            return true
        }

        mutating func beginNativeOpen() -> Bool {
            guard !nativeOpenAttempted else { return false }
            nativeOpenAttempted = true
            return true
        }
    }

    enum Provider: String, Equatable, Sendable {
        case googleDrive
        case dropbox

        var homeURL: URL {
            switch self {
            case .googleDrive: return URL(string: "https://drive.google.com/drive/my-drive")!
            case .dropbox: return URL(string: "https://www.dropbox.com/home")!
            }
        }
    }

    /// A single host-owned browser navigation in the W2 flow. The stage is
    /// the one-use identity; callers cannot supply arbitrary destinations.
    enum NavigationStage: String, Equatable, Sendable {
        case home
        case collisionSearch
        case returnToRoot
        case finalSearch
    }

    static let driveNoSearchMatchesText = "None of your files or folders matched this search"
    static let driveRootLocationLabel = "My Drive"

    static func displayedSize(byteCount: Int64, provider: Provider) -> String? {
        if provider == .googleDrive {
            // Drive's observed integer KB labels are calibrated only through 1 MiB.
            // Do not claim rounded MB/GB labels as exact completion evidence.
            guard (0...1_048_576).contains(byteCount) else { return nil }
            let formatter = ByteCountFormatter()
            formatter.countStyle = .binary
            formatter.allowedUnits = [.useBytes, .useKB]
            return formatter.string(fromByteCount: byteCount)
        }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    static func driveTitleSearchQuery(filename: String) -> String? {
        guard !filename.isEmpty, filename.utf8.count <= 240,
              !filename.contains("\""),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return "title:\"\(filename)\""
    }

    static func driveTitleSearchURL(filename: String) -> URL? {
        guard let query = driveTitleSearchQuery(filename: filename) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "drive.google.com"
        components.path = "/drive/search"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }

    static func isDriveTitleSearchURL(_ url: URL, filename: String) -> Bool {
        guard let expected = driveTitleSearchQuery(filename: filename),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.host?.lowercased() == "drive.google.com",
              components.path == "/drive/search", components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil,
              let items = components.queryItems, items.count == 1,
              items[0].name == "q", items[0].value == expected else { return false }
        return true
    }

    static func driveDetailsMatch(textValues: [String], candidate: ComputerUseLocalFileCatalog.Candidate) -> Bool {
        func normalized(_ value: String) -> String {
            value.replacingOccurrences(of: "\u{00A0}", with: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let values = textValues.map(normalized)
        guard values.filter({ $0 == candidate.displayName }).count == 1,
              values.contains("My Drive, show location in the list of files.") else { return false }
        guard let expectedSize = displayedSize(byteCount: candidate.byteCount, provider: .googleDrive) else {
            return false
        }
        let sizeEvidence = values.compactMap { value -> String? in
            guard value.hasPrefix("Size ") else { return nil }
            let suffix = String(value.dropFirst("Size ".count))
            return suffix.components(separatedBy: " Storage used ").first
        }
        return sizeEvidence.count == 1 && sizeEvidence[0] == expectedSize
    }

    struct Request: Equatable, Sendable {
        let provider: Provider
        let fileQuery: ComputerUseLocalFileCatalog.Query
        /// An optional folder label to resolve in the observed provider UI.
        /// It is never a URL or a path.
        let destinationFolder: String?

        init(provider: Provider, fileQuery: ComputerUseLocalFileCatalog.Query,
             destinationFolder: String? = nil) throws {
            guard fileQuery.isValid else { throw Failure.invalidRequest }
            if let destinationFolder {
                guard !destinationFolder.isEmpty, destinationFolder.utf8.count <= 512,
                      !destinationFolder.contains("/"), !destinationFolder.contains("\\"),
                      !destinationFolder.localizedCaseInsensitiveContains("://"),
                      !destinationFolder.unicodeScalars.contains(where: {
                          CharacterSet.controlCharacters.contains($0)
                      }) else { throw Failure.invalidRequest }
            }
            self.provider = provider
            self.fileQuery = fileQuery
            self.destinationFolder = destinationFolder
        }

        func openApprovalPresentation(candidate: ComputerUseLocalFileCatalog.Candidate,
                                      accountLabel: String) -> MCPComputerUseApprovalPresentation {
            MCPComputerUseApprovalPresentation(message: "Upload this file to \(provider.rawValue == "googleDrive" ? "Google Drive" : "Dropbox")?",
                details: [
                    .init(label: "Account", value: accountLabel),
                    .init(label: "File", value: candidate.displayName),
                    .init(label: "Size", value: "\(candidate.byteCount) bytes"),
                    .init(label: "Destination", value: destinationFolder ?? "Root folder"),
                ], confirmLabel: "Upload file")
        }
    }

    struct ListingRow: Equatable, Sendable {
        /// Values observed within one accessible row, in AX cell order.
        let rowID: String
        let cellLabels: [String]
        let frame: CGRect?

        init(rowID: String, cellLabels: [String], frame: CGRect? = nil) {
            self.rowID = rowID
            self.cellLabels = cellLabels
            self.frame = frame
        }
    }

    enum UploadProgress: Equatable, Sendable {
        case complete
        case inProgress
        case failed
        case unknown
    }

    enum ListingEvidence: Equatable, Sendable {
        case complete
        case inProgress
        case absent
        case ambiguous
        case mismatch
        case unverified
    }

    enum Failure: Error, Equatable {
        case invalidRequest
    }

    /// Fail closed until the provider row and completed-progress classifier is
    /// wired to a fresh, complete listing observation.
    static func listingEvidence(rows: [ListingRow], candidate: ComputerUseLocalFileCatalog.Candidate,
                                progress: UploadProgress, pageIsComplete: Bool,
                                expectedLocationLabel: String? = nil,
                                provider: Provider = .googleDrive) -> ListingEvidence {
        guard pageIsComplete else { return .unverified }
        switch progress {
        case .failed: return .mismatch
        case .inProgress: return .inProgress
        case .unknown: return .unverified
        case .complete: break
        }
        let namedRows = rows.filter { row in row.cellLabels.contains(candidate.displayName) }
        guard !namedRows.isEmpty else { return .absent }
        guard namedRows.count == 1 else { return .ambiguous }
        guard let expectedSize = displayedSize(byteCount: candidate.byteCount, provider: provider) else {
            return .mismatch
        }
        let hasSameRowSize = namedRows[0].cellLabels.contains { cell in
            let value = cell.trimmingCharacters(in: .whitespacesAndNewlines)
            if value == expectedSize { return true }
            guard let sizeRange = value.range(of: "Size:", options: [.caseInsensitive]) else { return false }
            let suffix = value[sizeRange.upperBound...]
            let displayed = suffix.components(separatedBy: "Storage used:").first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return displayed == expectedSize
        }
        if let expectedLocationLabel,
           !namedRows[0].cellLabels.contains(expectedLocationLabel) { return .mismatch }
        return hasSameRowSize ? .complete : .mismatch
    }

    static func uniqueDriveRootRow(rows: [ListingRow],
                                  candidate: ComputerUseLocalFileCatalog.Candidate) -> ListingRow? {
        let namedRows = rows.filter { $0.cellLabels.contains(candidate.displayName) }
        guard namedRows.count == 1, let row = namedRows.first,
              row.cellLabels.contains(driveRootLocationLabel) else { return nil }
        return row
    }

    static func selectedUploadCandidate(visibleCandidates: [ComputerUseLocalFileCatalog.Candidate],
                                        automaticCandidateID: String?,
                                        userSelectedCandidateID: String?) -> ComputerUseLocalFileCatalog.Candidate? {
        let candidateID = userSelectedCandidateID ?? automaticCandidateID
        guard let candidateID else { return nil }
        let matches = visibleCandidates.filter { $0.id == candidateID }
        return matches.count == 1 ? matches.first : nil
    }

    static func verifiesDriveCompletion(rows: [ListingRow],
                                        candidate: ComputerUseLocalFileCatalog.Candidate,
                                        progress: UploadProgress,
                                        pageIsComplete: Bool,
                                        detailsTextValues: [String]) -> Bool {
        guard progress == .complete, pageIsComplete,
              let row = uniqueDriveRootRow(rows: rows, candidate: candidate) else { return false }
        let listingSize = listingEvidence(rows: [row], candidate: candidate, progress: progress,
            pageIsComplete: true, expectedLocationLabel: driveRootLocationLabel) == .complete
        return listingSize || driveDetailsMatch(textValues: detailsTextValues, candidate: candidate)
    }
}
