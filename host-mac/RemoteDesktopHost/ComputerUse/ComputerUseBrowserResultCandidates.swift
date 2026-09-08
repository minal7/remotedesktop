import Foundation

enum ComputerUseBrowserResultError: Error, Equatable {
    case invalidPage, invalidProposal, contextLimit, goalChanged
}

/// Exact host snapshot plus the bounded projection offered for interpretation.
/// Controls are intentionally omitted from this reading-specific projection.
/// No destination, current form value or document authority enters its JSON.
struct ComputerUseBrowserResultPageInput: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let page: ComputerUseBrowserPageSnapshot
    let contextJSON: String
    fileprivate let textIDs: Set<String>
    fileprivate let linkIDs: Set<String>
    fileprivate let containerIDs: Set<String>
    let projectionOmittedRecords: Bool

    init(page: ComputerUseBrowserPageSnapshot) throws {
        guard page.isWellFormed else { throw ComputerUseBrowserResultError.invalidPage }
        self.page = page
        let reading = ComputerUseBrowserPageSnapshot(id: page.id, texts: page.texts, links: page.links,
            truncated: page.truncated, omittedEmbeddedContent: page.omittedEmbeddedContent,
            omittedControls: page.omittedControls || !page.controls.isEmpty, viewport: page.viewport,
            containers: page.containers, omittedStructure: page.omittedStructure)
        let context = try ComputerUseBrowserPlanningContext(page: reading).serialized()
        contextJSON = context
        var parser = StrictSemanticJSONParser(context, maximumValueCount: 2_048)
        guard case .object(let root) = try parser.parse(), case .array(let rows)? = root["records"],
              case .bool(let omitted)? = root["projection_omitted_records"] else { throw ComputerUseBrowserResultError.invalidPage }
        var texts: Set<String> = [], links: Set<String> = [], containers: Set<String> = []
        for row in rows {
            guard case .object(let item) = row, case .string(let kind)? = item["kind"], case .string(let id)? = item["id"] else {
                throw ComputerUseBrowserResultError.invalidPage
            }
            switch kind { case "text": texts.insert(id); case "link": links.insert(id); case "container": containers.insert(id)
            default: throw ComputerUseBrowserResultError.invalidPage }
        }
        textIDs = texts; linkIDs = links; containerIDs = containers; projectionOmittedRecords = omitted
    }
    var description: String { "BrowserResultPageInput(texts: \(textIDs.count), links: \(linkIDs.count))" }
    var debugDescription: String { description }
}

/// Model-selected grouping and field roles, never verified offer facts.
/// Selection uses only IDs actually exposed in this exact page projection.
struct ComputerUseBrowserResultProposal: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Kind: String, CaseIterable, Sendable {
        case title, category, origin, destination, location, date, time, price, fees, availability, quantity, other
    }
    struct Field: Equatable, Sendable {
        let kind: Kind
        let textIDs: [String]
    }
    struct Selection: Equatable, Sendable {
        let containerID: String
        let fields: [Field]
        let linkIDs: [String]
    }
    fileprivate let input: ComputerUseBrowserResultPageInput
    let goalRevision: String
    let selections: [Selection]
    private init(input: ComputerUseBrowserResultPageInput, goal: ComputerUseBrowserGoalInput, selections: [Selection]) {
        self.input = input; goalRevision = goal.digest; self.selections = selections
    }

    static func decode(content: String, input: ComputerUseBrowserResultPageInput, goal: ComputerUseBrowserGoalInput) throws -> Self {
        do { return try decodeContent(content, input: input, goal: goal) }
        catch { throw ComputerUseBrowserResultError.invalidProposal }
    }
    private static func decodeContent(_ content: String, input: ComputerUseBrowserResultPageInput, goal: ComputerUseBrowserGoalInput) throws -> Self {
        guard content.utf8.count <= 16 * 1_024 else { throw ComputerUseBrowserResultError.invalidProposal }
        var parser = StrictSemanticJSONParser(content, maximumValueCount: 1_024)
        guard case .object(let root) = try parser.parse(), Set(root.keys) == ["candidates"],
              case .array(let rows)? = root["candidates"], rows.count <= 8 else { throw ComputerUseBrowserResultError.invalidProposal }
        let page = input.page, tree = Tree(page)
        let textIndices = Dictionary(uniqueKeysWithValues: page.texts.enumerated().map { ($0.element.id, $0.offset) })
        let texts = Dictionary(uniqueKeysWithValues: page.texts.map { ($0.id, $0) })
        let links = Dictionary(uniqueKeysWithValues: page.links.map { ($0.id, $0) })
        var selections: [Selection] = [], references = 0
        for row in rows {
            guard case .object(let candidate) = row, Set(candidate.keys) == ["container", "fields", "links"],
                  case .string(let container)? = candidate["container"], input.containerIDs.contains(container),
                  let node = tree.nodes[container], node.parentID != nil,
                  ["article", "section", "div", "li", "tr", "listitem", "container"].contains(node.kind),
                  !selections.contains(where: { tree.contains($0.containerID, in: container) || tree.contains(container, in: $0.containerID) }),
                  case .array(let rows)? = candidate["fields"], (1...16).contains(rows.count),
                  case .array(let linkValues)? = candidate["links"], linkValues.count <= 16 else { throw ComputerUseBrowserResultError.invalidProposal }
            var fields: [Field] = [], usedTextIDs: Set<String> = []
            for row in rows {
                guard case .object(let field) = row, Set(field.keys) == ["kind", "texts"],
                      case .string(let kindValue)? = field["kind"], let kind = Kind(rawValue: kindValue),
                      case .array(let values)? = field["texts"], (1...16).contains(values.count) else { throw ComputerUseBrowserResultError.invalidProposal }
                var ids: [String] = [], previousIndex = -1
                for value in values {
                    guard case .string(let id) = value, input.textIDs.contains(id), let text = texts[id],
                          tree.contains(text.containerID, in: container), let index = textIndices[id], index > previousIndex,
                          usedTextIDs.insert(id).inserted else { throw ComputerUseBrowserResultError.invalidProposal }
                    ids.append(id); previousIndex = index; references += 1
                }
                fields.append(.init(kind: kind, textIDs: ids))
            }
            guard fields.filter({ $0.kind == .title }).count == 1 else { throw ComputerUseBrowserResultError.invalidProposal }
            var selectedLinks: [String] = []
            for value in linkValues {
                guard case .string(let id) = value, input.linkIDs.contains(id), !selectedLinks.contains(id), let link = links[id],
                      tree.contains(link, in: container) else {
                    throw ComputerUseBrowserResultError.invalidProposal
                }
                selectedLinks.append(id); references += 1
            }
            guard references <= 128 else { throw ComputerUseBrowserResultError.invalidProposal }
            selections.append(.init(containerID: container, fields: fields, linkIDs: selectedLinks))
        }
        // Document order is provenance, not an inferred price/ranking order.
        let indices = Dictionary(uniqueKeysWithValues: page.containers.enumerated().map { ($0.element.id, $0.offset) })
        selections.sort { indices[$0.containerID, default: 0] < indices[$1.containerID, default: 0] }
        return .init(input: input, goal: goal, selections: selections)
    }
    var description: String { "BrowserResultProposal(candidates: \(selections.count))" }
    var debugDescription: String { description }

    fileprivate struct Tree {
        let nodes: [String: ComputerUseBrowserPageSnapshot.Container]
        let textContainers: [String: String]
        init(_ page: ComputerUseBrowserPageSnapshot) {
            nodes = Dictionary(uniqueKeysWithValues: page.containers.map { ($0.id, $0) })
            textContainers = Dictionary(uniqueKeysWithValues: page.texts.map { ($0.id, $0.containerID) })
        }
        func contains(_ child: String, in ancestor: String) -> Bool {
            var current: String? = child
            while let id = current, let node = nodes[id] {
                if id == ancestor { return true }
                current = node.parentID
            }
            return false
        }
        func contains(_ link: ComputerUseBrowserPageSnapshot.Link, in container: String) -> Bool {
            guard let group = link.containerID,
                  link.textIDs.allSatisfy({ textContainers[$0].map { contains($0, in: container) } ?? false }) else { return false }
            if contains(group, in: container) { return true }
            // A card can itself be wrapped in an anchor. Its link's nearest
            // group is then outside the card, but all actual text references
            // must lie in this one subtree. A shared/global link cannot pass.
            return !link.textIDs.isEmpty && contains(container, in: group)
        }
    }
}

/// A source-bound reading candidate, not a verified offer. All surrounding
/// text/links in the selected subtree survive, including unclassified data.
/// No scalar observations, public URLs or completion claims are constructed.
struct ComputerUseBrowserResultCandidates: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Text: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let id: String
        let containerID: String
        let text: String
        var description: String { "BrowserResultText" }
        var debugDescription: String { description }
    }
    struct Link: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let id: String
        let containerID: String?
        let label: String
        let textIDs: [String]
        var description: String { "BrowserResultLink" }
        var debugDescription: String { description }
    }
    struct Candidate: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let id: String
        let containerID: String
        let fields: [ComputerUseBrowserResultProposal.Field]
        let texts: [Text]
        let links: [Link]
        let selectedLinkIDs: [String]
        let unclassifiedTextIDs: [String]
        let unprojectedTextIDs: [String]
        let unprojectedLinkIDs: [String]
        var description: String { "BrowserResultCandidate(fields: \(fields.count), texts: \(texts.count), links: \(links.count))" }
        var debugDescription: String { description }
    }
    enum DocumentAnswerSourceStatus: String, Sendable { case unconfigured, permitted, excluded }
    let goalRevision: String
    let candidates: [Candidate]
    let documentAnswerSourceStatus: DocumentAnswerSourceStatus
    fileprivate let answerSourcePolicy: ComputerUseBrowserAnswerSourcePolicy?
    let containers: [ComputerUseBrowserPageSnapshot.Container]
    let surroundingTexts: [Text]
    let surroundingLinks: [Link]
    let sourceTruncated: Bool
    let omittedStructure: Bool
    let omittedEmbeddedContent: Bool
    let omittedControls: Bool
    let projectionOmittedRecords: Bool
    fileprivate let evidence: ComputerUseBrowserPageEvidence
    fileprivate let rootTaskID: String
    fileprivate let readingInput: ComputerUseBrowserResultPageInput

    fileprivate init(proposal: ComputerUseBrowserResultProposal, goal: ComputerUseBrowserGoalInput,
                     evidence: ComputerUseBrowserPageEvidence, answerPolicy: ComputerUseBrowserAnswerSourcePolicy?) {
        self.evidence = evidence; goalRevision = goal.digest; rootTaskID = goal.taskID
        answerSourcePolicy = answerPolicy
        documentAnswerSourceStatus = answerPolicy.map { $0.permitsEvidenceFrom(evidence.document.committedURL) ? .permitted : .excluded } ?? .unconfigured
        readingInput = proposal.input
        let page = evidence.page, tree = ComputerUseBrowserResultProposal.Tree(page)
        containers = page.containers
        sourceTruncated = page.truncated; omittedStructure = page.omittedStructure
        omittedEmbeddedContent = page.omittedEmbeddedContent
        omittedControls = page.omittedControls || !page.controls.isEmpty
        projectionOmittedRecords = proposal.input.projectionOmittedRecords
        func text(_ item: ComputerUseBrowserPageSnapshot.Text) -> Text { .init(id: item.id, containerID: item.containerID, text: item.text) }
        func link(_ item: ComputerUseBrowserPageSnapshot.Link) -> Link { .init(id: item.id, containerID: item.containerID, label: item.label, textIDs: item.textIDs) }
        var includedTexts: Set<String> = [], includedLinks: Set<String> = []
        candidates = proposal.selections.map { selection in
            let texts = page.texts.filter { tree.contains($0.containerID, in: selection.containerID) }
            let links = page.links.filter { tree.contains($0, in: selection.containerID) }
            includedTexts.formUnion(texts.map(\.id)); includedLinks.formUnion(links.map(\.id))
            let assigned = Set(selection.fields.flatMap(\.textIDs))
            let identity = ["browser-result-candidate-v1", goal.digest, evidence.document.contextID,
                String(evidence.document.generation), evidence.documentID, page.id, selection.containerID]
                + selection.fields.flatMap { [$0.kind.rawValue, String($0.textIDs.count)] + $0.textIDs }
                + [String(selection.linkIDs.count)] + selection.linkIDs
                + (answerPolicy.map { ["answer-source-policy", $0.digest] } ?? [])
            return Candidate(id: ComputerUseTaskContract.digest(identity), containerID: selection.containerID, fields: selection.fields,
                texts: texts.map(text), links: links.map(link), selectedLinkIDs: selection.linkIDs,
                unclassifiedTextIDs: texts.filter { !assigned.contains($0.id) }.map(\.id),
                unprojectedTextIDs: texts.filter { !proposal.input.textIDs.contains($0.id) }.map(\.id),
                unprojectedLinkIDs: links.filter { !proposal.input.linkIDs.contains($0.id) }.map(\.id))
        }
        surroundingTexts = page.texts.filter { !includedTexts.contains($0.id) }.map(text)
        surroundingLinks = page.links.filter { !includedLinks.contains($0.id) }.map(link)
    }
    var description: String { "BrowserResultCandidates(candidates: \(candidates.count), truncated: \(sourceTruncated))" }
    var debugDescription: String { description }
}

/// Immutable proposal context for one bound reading and confirmed history.
/// The original bounded page projection remains intact; native destinations,
/// session identity and candidate authority stay outside the model message.
struct ComputerUseBrowserLinkSelectionInput: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private struct Choice: Equatable, Sendable { let candidateID: String; let links: [String] }
    private let choices: [Choice]
    private let bindingDigest: String
    let contextJSON: String
    var candidateCount: Int { choices.count }
    var selectableLinkIDs: [String] { Array(Set(choices.flatMap(\.links))).sorted() }
    var hasSelectableLinks: Bool { choices.contains { !$0.links.isEmpty } }

    init(goal: ComputerUseBrowserGoalInput, candidates: ComputerUseBrowserResultCandidates,
         history: [ComputerUseBrowserResearchVisit]) throws {
        guard candidates.goalRevision == goal.digest, candidates.rootTaskID == goal.taskID,
              history.count <= 33, history.allSatisfy({ $0.rootDigest == goal.rootDigest }),
              Set(history.map(\.operationID)).count == history.count else {
            throw ComputerUseBrowserLinkPlanError.inputChanged
        }
        choices = candidates.candidates.map { .init(candidateID: $0.id, links: $0.selectedLinkIDs) }
        let groups: [[String: Any]] = candidates.candidates.enumerated().map { index, candidate in
            ["index":index, "container":candidate.containerID,
             "fields":candidate.fields.map { ["kind":$0.kind.rawValue, "texts":$0.textIDs] as [String: Any] },
             "links":candidate.selectedLinkIDs,
             "unclassified_texts":candidate.unclassifiedTextIDs.filter { candidates.readingInput.textIDs.contains($0) },
             "unprojected_text_count":candidate.unprojectedTextIDs.count,
             "unprojected_link_count":candidate.unprojectedLinkIDs.count]
        }
        let visits: [[String: Any]] = history.enumerated().map {
            ["step":$0.offset, "kind":$0.element.kind.rawValue, "current_goal_revision":$0.element.goalRevision == goal.digest]
        }
        let context: [String: Any] = ["version":2, "goal":goal.plannerContext,
            "page":try JSONSerialization.jsonObject(with: Data(candidates.readingInput.contextJSON.utf8)),
            "candidates":groups, "navigation_history":visits,
            "document_answer_source_status":candidates.documentAnswerSourceStatus.rawValue]
        contextJSON = String(decoding: try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]), as: UTF8.self)
        let evidence = candidates.evidence
        bindingDigest = ComputerUseTaskContract.digest(["browser-link-selection-input-v1", goal.digest,
            evidence.document.contextID, String(evidence.document.generation), evidence.documentID, evidence.page.id, contextJSON]
            + choices.flatMap { [$0.candidateID, String($0.links.count)] + $0.links }
            + (candidates.answerSourcePolicy.map { ["answer-source-policy", $0.digest] } ?? [])
            + history.flatMap { [$0.operationID, $0.goalRevision, $0.kind.rawValue] })
    }

    func resolve(candidate: Int, link: String) throws -> ComputerUseBrowserResearchTask.LinkChoice? {
        if candidate == -1, link.isEmpty { return nil }
        guard choices.indices.contains(candidate), choices[candidate].links.contains(link) else {
            throw ComputerUseBrowserLinkPlanError.invalidProposal
        }
        return .init(candidateID: choices[candidate].candidateID, linkID: link)
    }
    var description: String { "BrowserLinkSelectionInput(candidates: \(candidateCount))" }
    var debugDescription: String { description }
}

extension ComputerUseOwnedBrowser {
    /// Drill into a link selected from one actual reading candidate. Exact
    /// destinations remain inside native evidence and are revalidated by the
    /// existing link-navigation boundary. This does not certify offer meaning.
    func prepareResultLinkNavigation(_ batch: ComputerUseBrowserResultCandidates, candidateID: String, linkID: String,
                                     goal: ComputerUseBrowserGoalInput) async throws -> ComputerUseBrowserNavigationTarget {
        try Task.checkCancellation()
        guard let candidate = batch.candidates.first(where: { $0.id == candidateID }),
              candidate.selectedLinkIDs.contains(linkID), candidate.links.contains(where: { $0.id == linkID }) else {
            throw ComputerUseBrowserResultError.invalidProposal
        }
        try await validateResultCandidates(batch, goal: goal)
        try Task.checkCancellation()
        return try await prepareLinkNavigation(linkID: linkID, evidence: batch.evidence)
    }

    /// Preparation rereads the native page before returning source bindings.
    /// It neither follows links nor certifies semantic offer associations.
    func prepareResultCandidates(_ proposal: ComputerUseBrowserResultProposal, goal: ComputerUseBrowserGoalInput,
                                 evidence: ComputerUseBrowserPageEvidence,
                                 answerPolicy: ComputerUseBrowserAnswerSourcePolicy? = nil) async throws -> ComputerUseBrowserResultCandidates {
        try Task.checkCancellation()
        guard proposal.goalRevision == goal.digest, goal.taskID.utf8.elementsEqual(evidence.document.taskID.utf8),
              answerPolicy == nil || answerPolicy?.goalRevision == goal.digest else {
            throw ComputerUseBrowserResultError.goalChanged
        }
        guard proposal.input.page == evidence.page else { throw ComputerUseBrowserResultError.invalidPage }
        try await validatePageEvidence(evidence)
        try Task.checkCancellation()
        return .init(proposal: proposal, goal: goal, evidence: evidence, answerPolicy: answerPolicy)
    }

    /// A necessary source check for future answer assembly, never sufficient
    /// result verification. Search snippets and labels naming an allowed site
    /// do not change the actual document origin that supplied their content.
    func validateResultAnswerSource(_ batch: ComputerUseBrowserResultCandidates, goal: ComputerUseBrowserGoalInput,
                                    policy: ComputerUseBrowserAnswerSourcePolicy) async throws {
        try Task.checkCancellation()
        guard policy.goalRevision == goal.digest, batch.answerSourcePolicy == policy,
              batch.documentAnswerSourceStatus == .permitted else { throw ComputerUseBrowserError.sourceNotAllowed }
        try await validateResultCandidates(batch, goal: goal)
        try Task.checkCancellation()
        guard policy.permitsEvidenceFrom(batch.evidence.document.committedURL) else { throw ComputerUseBrowserError.sourceNotAllowed }
    }

    /// Reporting later must revalidate against the actual current goal and
    /// live owned document. Retained records are historical after navigation.
    func validateResultCandidates(_ batch: ComputerUseBrowserResultCandidates, goal: ComputerUseBrowserGoalInput) async throws {
        try Task.checkCancellation()
        guard goal.digest == batch.goalRevision, goal.taskID.utf8.elementsEqual(batch.rootTaskID.utf8) else {
            throw ComputerUseBrowserResultError.goalChanged
        }
        try await validatePageEvidence(batch.evidence)
        try Task.checkCancellation()
    }
}
