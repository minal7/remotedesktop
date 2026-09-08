import Foundation

/// A current, source-bound progress update. It contains observations and the
/// entire unresolved requirement ledger, never a completed research answer.
/// URLs are native output for the user; this type has no planner projection.
struct ComputerUseBrowserResearchReport: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Passage: Sendable {
        let text: String
        let detailsLinks: [String]
        let omittedLinks: Int
    }
    static let maximumBytes = ComputerUseResearchProgress.maximumTextBytes
    static let maximumPassageBytes = 4 * 1_024
    let goalRevision: String
    let rootTaskID: String
    let readingIdentity: String
    let message: String
    let passageCount: Int
    let requirementCount: Int
    var progress: ComputerUseResearchProgress? {
        try? .init(reportID: ComputerUseTaskContract.digest([
            "browser-research-report-v1", rootTaskID, goalRevision, readingIdentity, message]), text: message)
    }
    static let guidance = "I found page passages to review. The research answer is still unverified. Review the findings and page, then choose Resume to continue the original task."

    /// Keep the exact address or omit it. Removing a query/fragment could
    /// invent a different source; carrying one could expose session state.
    /// This is an export-format check, not proof of public access or relevance.
    static func reportableURL(_ url: URL) -> String? {
        guard let valid = ComputerUseOwnedBrowser.validatedURL(url),
              let parts = URLComponents(url: valid, resolvingAgainstBaseURL: false),
              parts.query == nil, parts.fragment == nil,
              valid.absoluteString.utf8.count <= 2_048 else { return nil }
        return valid.absoluteString
    }

    init?(rootTaskID: String, goalRevision: String, readingIdentity: String, site: String, sourceLink: String?,
          passages: [Passage], surroundingText: String, requirements: [String], incompleteReading: Bool) {
        guard !passages.isEmpty, passages.count <= 8, !requirements.isEmpty,
              [site, surroundingText].allSatisfy(Self.printable),
              requirements.allSatisfy(Self.printable), passages.allSatisfy({ Self.printable($0.text) }) else { return nil }
        self.rootTaskID = rootTaskID; self.goalRevision = goalRevision; self.readingIdentity = readingIdentity
        requirementCount = requirements.count
        var message = "I found page passages to review, but the complete research answer is still unverified. The original task remains pending.\n\n"
        message += "Page source: " + site + "\n"
        if let sourceLink { message += "Source page: " + sourceLink + "\n" }
        else { message += "A source-page address is not included in this update.\n" }
        if incompleteReading {
            message += "This reading is incomplete. It cannot establish availability, distinct options or the full result set.\n"
        }
        // Keep all surrounding native text, including qualifiers not selected
        // by either model. If it does not fit, decline the whole report.
        if !surroundingText.isEmpty {
            message += "\nOther observed page text (quoted):\n" + Self.quote(surroundingText) + "\n"
        }
        let pending = "\nStill to verify against your request:\n"
            + requirements.enumerated().map { "\($0.offset + 1). " + Self.quote($0.element) }.joined(separator: "\n")
            + "\n\nChoose Resume after reviewing the page to continue the original task."
        guard (message + pending).utf8.count <= Self.maximumBytes else { return nil }
        var included = 0
        for passage in passages {
            guard !passage.text.isEmpty, passage.text.utf8.count <= Self.maximumPassageBytes else { continue }
            var block = "\nPage passage \(included + 1) (quoted; offer details are not verified):\n" + Self.quote(passage.text) + "\n"
            for link in passage.detailsLinks { block += "Observed details link: " + link + "\n" }
            if passage.omittedLinks > 0 { block += "Some observed links are not included in this update.\n" }
            // Reserve the complete unresolved ledger and an omission notice.
            guard (message + block + pending).utf8.count + 128 <= Self.maximumBytes else { continue }
            message += block; included += 1
        }
        guard included > 0 else { return nil }
        if included < passages.count { message += "\n\(passages.count - included) additional page passages were too large for this update.\n" }
        message += pending
        guard message.utf8.count <= Self.maximumBytes else { return nil }
        self.message = message; passageCount = included
    }

    private static func printable(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) && scalar != "\n" && scalar != "\t"
        }
    }
    /// The shipped phone view uses literal Text, not Markdown. Prefix every
    /// line so page-authored instructions remain visibly quoted data there.
    private static func quote(_ text: String) -> String {
        text.components(separatedBy: "\n").map { "│ " + $0 }.joined(separator: "\n")
    }
    var description: String { "BrowserResearchReport(passages: \(passageCount), requirements: \(requirementCount))" }
    var debugDescription: String { description }
}
