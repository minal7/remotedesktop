import Foundation

enum ComputerUseBrowserResultError: Error, Equatable {
    case invalidPage, invalidProposal, contextLimit, goalChanged
}

/// Exact host snapshot plus the bounded projection offered for interpretation.
/// Research-only native control states remain separate from quoted page text.
/// No destination, submission value or document authority enters its JSON.
struct ComputerUseBrowserResultPageInput: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let page: ComputerUseBrowserPageSnapshot
    let contextJSON: String
    fileprivate let textIDs: Set<String>
    fileprivate let linkIDs: Set<String>
    fileprivate let containerIDs: Set<String>
    let controlIDs: Set<String>
    fileprivate let projectedControlIDs: Set<String>
    let projectionOmittedRecords: Bool

    init(page: ComputerUseBrowserPageSnapshot) throws {
        guard page.isWellFormed else { throw ComputerUseBrowserResultError.invalidPage }
        self.page = page
        let reading = ComputerUseBrowserPageSnapshot(id: page.id, texts: page.texts, links: page.links,
            controls: page.controlStateObserved ? page.controls : [],
            truncated: page.truncated, omittedEmbeddedContent: page.omittedEmbeddedContent,
            omittedControls: page.omittedControls || (page.controlStateObserved ? page.controlStates.contains { $0.kind == .unavailable } : !page.controls.isEmpty),
            viewport: page.viewport, containers: page.containers, omittedStructure: page.omittedStructure,
            controlStates: page.controlStates, controlStateObserved: page.controlStateObserved)
        let context = try ComputerUseBrowserPlanningContext(page: reading, includingControlState: page.controlStateObserved).serialized()
        contextJSON = context
        var parser = StrictSemanticJSONParser(context, maximumValueCount: 2_048)
        guard case .object(let root) = try parser.parse(), case .array(let rows)? = root["records"],
              case .bool(let omitted)? = root["projection_omitted_records"] else { throw ComputerUseBrowserResultError.invalidPage }
        var texts: Set<String> = [], links: Set<String> = [], containers: Set<String> = [], controls: Set<String> = []
        for row in rows {
            guard case .object(let item) = row, case .string(let kind)? = item["kind"], case .string(let id)? = item["id"] else {
                throw ComputerUseBrowserResultError.invalidPage
            }
            switch kind { case "text": texts.insert(id); case "link": links.insert(id); case "container": containers.insert(id)
            case "control": controls.insert(id)
            default: throw ComputerUseBrowserResultError.invalidPage }
        }
        textIDs = texts; linkIDs = links; containerIDs = containers; projectionOmittedRecords = omitted
        projectedControlIDs = controls
        controlIDs = Set(page.controls.filter { control in controls.contains(control.id)
            && page.controlStates.first(where: { $0.controlID == control.id })?.fieldSource(for: control) != nil }.map(\.id))
    }
    func projectedSourceIDs(in container: String) -> Set<String> {
        let tree = ComputerUseBrowserResultProposal.Tree(page)
        return Set(page.texts.filter { textIDs.contains($0.id) && tree.contains($0.containerID, in: container) }.map(\.id))
            .union(page.controls.filter { controlIDs.contains($0.id) && tree.contains($0.containerID, in: container) }.map(\.id))
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
        let controlIDs: [String]
        init(kind: Kind, textIDs: [String], controlIDs: [String] = []) { self.kind = kind; self.textIDs = textIDs; self.controlIDs = controlIDs }
    }
    struct Selection: Equatable, Sendable {
        let containerID: String
        let fields: [Field]
        let linkIDs: [String]
    }
    fileprivate let input: ComputerUseBrowserResultPageInput
    let goalRevision: String
    let selections: [Selection]
    let review: ComputerUseBrowserResultReview?
    private init(input: ComputerUseBrowserResultPageInput, goal: ComputerUseBrowserGoalInput, selections: [Selection],
                 review: ComputerUseBrowserResultReview? = nil) {
        self.input = input; goalRevision = goal.digest; self.selections = selections; self.review = review
    }

    func validateReviewInput(page: ComputerUseBrowserResultPageInput, goal: ComputerUseBrowserGoalInput) throws {
        guard input == page, goalRevision == goal.digest else { throw ComputerUseBrowserResultReviewError.inputChanged }
    }

    func reviewed(_ review: ComputerUseBrowserResultReview, goal: ComputerUseBrowserGoalInput,
                  interpretation: ComputerUseBrowserGoalProposal? = nil) throws -> Self {
        let reviewInput = try ComputerUseBrowserResultReviewInput(goal: goal, page: input, proposal: self, interpretation: interpretation)
        try review.validate(for: reviewInput)
        guard self.review == nil || self.review == review else { throw ComputerUseBrowserResultReviewError.inputChanged }
        return .init(input: input, goal: goal, selections: selections, review: review)
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
        let controls = Dictionary(uniqueKeysWithValues: page.controls.map { ($0.id, $0) })
        var selections: [Selection] = [], references = 0
        for row in rows {
            guard case .object(let candidate) = row, Set(candidate.keys) == ["container", "fields", "links"],
                  case .string(let container)? = candidate["container"], input.containerIDs.contains(container),
                  let node = tree.nodes[container], node.parentID != nil,
                  ["article", "section", "div", "li", "tr", "listitem", "container"].contains(node.kind),
                  !selections.contains(where: { tree.contains($0.containerID, in: container) || tree.contains(container, in: $0.containerID) }),
                  case .array(let rows)? = candidate["fields"], (1...16).contains(rows.count),
                  case .array(let linkValues)? = candidate["links"], linkValues.count <= 16 else { throw ComputerUseBrowserResultError.invalidProposal }
            var fields: [Field] = [], usedTextIDs: Set<String> = [], usedControlIDs: Set<String> = []
            for row in rows {
                guard case .object(let field) = row,
                      Set(field.keys) == ["kind", "texts"] || (page.controlStateObserved && Set(field.keys) == ["kind", "texts", "controls"]),
                      case .string(let kindValue)? = field["kind"], let kind = Kind(rawValue: kindValue),
                      case .array(let values)? = field["texts"], values.count <= 16 else { throw ComputerUseBrowserResultError.invalidProposal }
                var ids: [String] = [], previousIndex = -1
                for value in values {
                    guard case .string(let id) = value, input.textIDs.contains(id), let text = texts[id],
                          tree.contains(text.containerID, in: container), let index = textIndices[id], index > previousIndex,
                          usedTextIDs.insert(id).inserted else { throw ComputerUseBrowserResultError.invalidProposal }
                    ids.append(id); previousIndex = index; references += 1
                }
                let controlValues: [MCPJSONValue]
                if let value = field["controls"] {
                    guard case .array(let entries) = value, entries.count <= 16 else { throw ComputerUseBrowserResultError.invalidProposal }
                    controlValues = entries
                } else { controlValues = [] }
                var controlIDs: [String] = []
                for value in controlValues {
                    guard case .string(let id) = value, input.controlIDs.contains(id), let control = controls[id],
                          tree.contains(control.containerID, in: container), usedControlIDs.insert(id).inserted else { throw ComputerUseBrowserResultError.invalidProposal }
                    controlIDs.append(id); references += 1
                }
                guard page.controls.filter({ controlIDs.contains($0.id) }).map(\.id) == controlIDs else { throw ComputerUseBrowserResultError.invalidProposal }
                guard !ids.isEmpty || !controlIDs.isEmpty, kind != .title || (!ids.isEmpty && controlIDs.isEmpty) else { throw ComputerUseBrowserResultError.invalidProposal }
                fields.append(.init(kind: kind, textIDs: ids, controlIDs: controlIDs))
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
        let controls: [ControlObservation]
        let selectedLinkIDs: [String]
        let unclassifiedTextIDs: [String]
        let unprojectedTextIDs: [String]
        let unprojectedLinkIDs: [String]
        let unprojectedControlIDs: [String]
        func source(for field: ComputerUseBrowserResultProposal.Field) -> String {
            (field.textIDs.compactMap { id in texts.first { $0.id == id }?.text }
                + field.controlIDs.compactMap { id in controls.first { $0.control.id == id }?.fieldSource }).joined(separator: "\n")
        }
        var description: String { "BrowserResultCandidate(fields: \(fields.count), texts: \(texts.count), links: \(links.count))" }
        var debugDescription: String { description }
    }
    struct ControlObservation: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let control: ComputerUseBrowserPageSnapshot.Control
        let state: ComputerUseBrowserControlState?
        var fieldSource: String? { state?.fieldSource(for: control) }
        var renderedObservation: String { state?.renderedObservation(for: control) ?? "Control state was not observed." }
        var description: String { "BrowserResultControl(kind: \(control.kind))" }
        var debugDescription: String { description }
    }
    enum DocumentAnswerSourceStatus: String, Sendable { case unconfigured, permitted, excluded }
    let goalRevision: String
    /// Host wall-clock time after native reading validation, not the user's
    /// fixed date context and not a promise that inventory remains current.
    let observedAtMilliseconds: Int64
    let historyOptions: [ComputerUseBrowserHistoryOption]
    let candidates: [Candidate]
    let review: ComputerUseBrowserResultReview?
    let documentAnswerSourceStatus: DocumentAnswerSourceStatus
    fileprivate let answerSourcePolicy: ComputerUseBrowserAnswerSourcePolicy?
    fileprivate let goalInterpretation: ComputerUseBrowserGoalProposal?
    let containers: [ComputerUseBrowserPageSnapshot.Container]
    let surroundingTexts: [Text]
    let surroundingLinks: [Link]
    let surroundingControls: [ControlObservation]
    let sourceTruncated: Bool
    let omittedStructure: Bool
    let omittedEmbeddedContent: Bool
    let omittedControls: Bool
    let projectionOmittedRecords: Bool
    fileprivate let evidence: ComputerUseBrowserPageEvidence
    fileprivate let rootTaskID: String
    fileprivate let readingInput: ComputerUseBrowserResultPageInput

    var requirementAssessmentIdentity: String {
        ComputerUseTaskContract.digest(["browser-reading-assessment-v2", goalRevision, String(observedAtMilliseconds), evidence.document.contextID,
            String(evidence.document.generation), evidence.documentID, evidence.page.id, answerSourcePolicy?.digest ?? "", review?.digest ?? "",
            goalInterpretation?.digest ?? ""] + candidates.map(\.id))
    }
    var requirementAssessment: ComputerUseBrowserResultAssessment? {
        guard let goalInterpretation else { return nil }
        return try? .init(interpretation: goalInterpretation, reading: self)
    }

    func validateHistoricalGoal(_ goal: ComputerUseBrowserGoalInput) throws {
        guard rootTaskID == goal.taskID, goalRevision == goal.digest,
              goalInterpretation?.input == goal else { throw ComputerUseBrowserResearchEvidenceError.inputChanged }
    }
    var historicalSessionIdentity: String { evidence.document.contextID }
    var historicalSourceIdentity: String { ComputerUseTaskContract.digest([evidence.document.committedURL.absoluteString]) }
    func hasSameAnswerInterpretationAndPolicy(as current: Self) -> Bool {
        goalInterpretation?.digest == current.goalInterpretation?.digest && answerSourcePolicy == current.answerSourcePolicy
    }

    func answerPage(goal: ComputerUseBrowserGoalInput) -> ComputerUseBrowserResearchAnswer.Page? {
        guard goalRevision == goal.digest, rootTaskID == goal.taskID,
              let interpretation = goalInterpretation,
              let source = ComputerUseBrowserResearchReport.reportableURL(evidence.document.committedURL) else { return nil }
        return .init(goal: goal, reading: self, interpretation: interpretation, source: source)
    }

    func answerEligibility(goal: ComputerUseBrowserGoalInput, evidence: ComputerUseBrowserResearchEvidence? = nil,
                           recalledReadings: [Int] = []) throws -> ComputerUseBrowserResearchAnswer.Eligibility? {
        try .init(goal: goal, current: self, evidence: evidence, recalledReadings: recalledReadings)
    }

    /// Full original bounded reading projection with its original assessment.
    /// Native IDs/URLs remain private. Old reference IDs are local to this
    /// observation and cannot be used as current-page actions.
    func historicalPlannerContext() throws -> [String: Any] {
        ["observed_at_milliseconds":observedAtMilliseconds,
         "page":try JSONSerialization.jsonObject(with: Data(readingInput.contextJSON.utf8)),
         "candidates":candidatePlannerContext,
         "document_answer_source_status_at_reading":documentAnswerSourceStatus.rawValue,
         "field_review":review.map { $0.plannerContext as Any } ?? NSNull(),
         "requirement_assessment_at_reading":requirementAssessment.map { $0.plannerContext as Any } ?? NSNull()]
    }

    fileprivate var candidatePlannerContext: [[String: Any]] {
        candidates.enumerated().map { index, candidate in
            ["index":index, "container":candidate.containerID,
             "fields":candidate.fields.map { ["kind":$0.kind.rawValue, "texts":$0.textIDs, "controls":$0.controlIDs] as [String: Any] },
             "links":candidate.selectedLinkIDs,
             "unclassified_texts":candidate.unclassifiedTextIDs.filter { readingInput.textIDs.contains($0) },
             "unprojected_text_count":candidate.unprojectedTextIDs.count,
             "unprojected_link_count":candidate.unprojectedLinkIDs.count,
             "unprojected_control_count":candidate.unprojectedControlIDs.count]
        }
    }

    fileprivate init(proposal: ComputerUseBrowserResultProposal, goal: ComputerUseBrowserGoalInput,
                     evidence: ComputerUseBrowserPageEvidence, answerPolicy: ComputerUseBrowserAnswerSourcePolicy?,
                     interpretation: ComputerUseBrowserGoalProposal?, historyOptions: [ComputerUseBrowserHistoryOption]) {
        self.evidence = evidence; goalRevision = goal.digest; rootTaskID = goal.taskID
        observedAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        self.historyOptions = historyOptions
        answerSourcePolicy = answerPolicy
        goalInterpretation = interpretation; review = proposal.review
        documentAnswerSourceStatus = answerPolicy.map { $0.permitsEvidenceFrom(evidence.document.committedURL) ? .permitted : .excluded } ?? .unconfigured
        readingInput = proposal.input
        let page = evidence.page, tree = ComputerUseBrowserResultProposal.Tree(page)
        containers = page.containers
        sourceTruncated = page.truncated; omittedStructure = page.omittedStructure
        omittedEmbeddedContent = page.omittedEmbeddedContent
        omittedControls = page.omittedControls || (page.controlStateObserved ? page.controlStates.contains { $0.kind == .unavailable } : !page.controls.isEmpty)
        projectionOmittedRecords = proposal.input.projectionOmittedRecords
        func text(_ item: ComputerUseBrowserPageSnapshot.Text) -> Text { .init(id: item.id, containerID: item.containerID, text: item.text) }
        func link(_ item: ComputerUseBrowserPageSnapshot.Link) -> Link { .init(id: item.id, containerID: item.containerID, label: item.label, textIDs: item.textIDs) }
        func control(_ item: ComputerUseBrowserPageSnapshot.Control) -> ControlObservation {
            .init(control: item, state: page.controlStates.first { $0.controlID == item.id })
        }
        var includedTexts: Set<String> = [], includedLinks: Set<String> = [], includedControls: Set<String> = []
        candidates = proposal.selections.map { selection in
            let texts = page.texts.filter { tree.contains($0.containerID, in: selection.containerID) }
            let links = page.links.filter { tree.contains($0, in: selection.containerID) }
            let controls = page.controls.filter { tree.contains($0.containerID, in: selection.containerID) }
            includedTexts.formUnion(texts.map(\.id)); includedLinks.formUnion(links.map(\.id))
            includedControls.formUnion(controls.map(\.id))
            let assigned = Set(selection.fields.flatMap(\.textIDs))
            let identity = ["browser-result-candidate-v2", goal.digest, evidence.document.contextID,
                String(evidence.document.generation), evidence.documentID, page.id, selection.containerID]
                + selection.fields.flatMap { [$0.kind.rawValue, String($0.textIDs.count)] + $0.textIDs + [String($0.controlIDs.count)] + $0.controlIDs }
                + [String(selection.linkIDs.count)] + selection.linkIDs
                + (answerPolicy.map { ["answer-source-policy", $0.digest] } ?? [])
                + (proposal.review.map { ["semantic-review", $0.digest] } ?? [])
            return Candidate(id: ComputerUseTaskContract.digest(identity), containerID: selection.containerID, fields: selection.fields,
                texts: texts.map(text), links: links.map(link), controls: controls.map(control), selectedLinkIDs: selection.linkIDs,
                unclassifiedTextIDs: texts.filter { !assigned.contains($0.id) }.map(\.id),
                unprojectedTextIDs: texts.filter { !proposal.input.textIDs.contains($0.id) }.map(\.id),
                unprojectedLinkIDs: links.filter { !proposal.input.linkIDs.contains($0.id) }.map(\.id),
                unprojectedControlIDs: controls.filter { !proposal.input.projectedControlIDs.contains($0.id) }.map(\.id))
        }
        surroundingTexts = page.texts.filter { !includedTexts.contains($0.id) }.map(text)
        surroundingLinks = page.links.filter { !includedLinks.contains($0.id) }.map(link)
        surroundingControls = page.controls.filter { !includedControls.contains($0.id) }.map(control)
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
    private let answerEligibility: ComputerUseBrowserResearchAnswer.Eligibility?
    let historyOptions: [ComputerUseBrowserHistoryOption]
    var historyVisitIndices: [Int] { historyOptions.map(\.visit) }
    let allowsAnswer: Bool
    var answerCandidateIndices: [Int] { answerEligibility?.candidateIndices ?? [] }
    var answerCounts: [Int] { answerEligibility?.selectionCounts ?? [] }
    var answerOptions: [[String: Any]] { answerEligibility?.plannerOptions ?? [] }
    let recallableReadingIndices: [Int]
    let contextJSON: String
    var candidateCount: Int { choices.count }
    var selectableLinkIDs: [String] { Array(Set(choices.flatMap(\.links))).sorted() }
    var hasSelectableLinks: Bool { choices.contains { !$0.links.isEmpty } }
    var hasPlanningChoices: Bool { hasSelectableLinks || !recallableReadingIndices.isEmpty || !answerCounts.isEmpty || !historyOptions.isEmpty }

    init(goal: ComputerUseBrowserGoalInput, candidates: ComputerUseBrowserResultCandidates,
         history: [ComputerUseBrowserResearchVisit], evidence: ComputerUseBrowserResearchEvidence? = nil,
         recalledReadings: [Int] = [], allowsAnswer: Bool = false) throws {
        guard candidates.goalRevision == goal.digest, candidates.rootTaskID == goal.taskID,
              history.count <= 33, history.allSatisfy({ $0.rootDigest == goal.rootDigest }),
              Set(history.map(\.operationID)).count == history.count else {
            throw ComputerUseBrowserLinkPlanError.inputChanged
        }
        try evidence?.validate(goal: goal, current: candidates)
        let available = evidence?.selectableIndices(current: candidates) ?? []
        guard recalledReadings.count <= ComputerUseBrowserResearchEvidence.maximumRecalledReadings,
              Set(recalledReadings).count == recalledReadings.count,
              recalledReadings.allSatisfy({ available.contains($0) }) else { throw ComputerUseBrowserLinkPlanError.inputChanged }
        recallableReadingIndices = recalledReadings.count < ComputerUseBrowserResearchEvidence.maximumRecalledReadings
            ? available.filter { !recalledReadings.contains($0) } : []
        choices = candidates.candidates.map { .init(candidateID: $0.id, links: $0.selectedLinkIDs) }
        self.allowsAnswer = allowsAnswer
        historyOptions = allowsAnswer ? candidates.historyOptions : []
        guard Set(historyOptions.map(\.visit)).count == historyOptions.count,
              historyOptions.allSatisfy({ history.indices.contains($0.visit)
                && history[$0.visit].operationID == $0.operationID && $0.target.isBound(to: candidates.evidence) }) else {
            throw ComputerUseBrowserLinkPlanError.inputChanged
        }
        answerEligibility = allowsAnswer ? try candidates.answerEligibility(goal: goal, evidence: evidence, recalledReadings: recalledReadings) : nil
        let visits: [[String: Any]] = history.enumerated().map {
            ["step":$0.offset, "kind":$0.element.kind.rawValue, "current_goal_revision":$0.element.goalRevision == goal.digest]
        }
        let assessment = candidates.requirementAssessment
        let readingCatalog: Any
        if let evidence { readingCatalog = try evidence.catalog(goal: goal, current: candidates) }
        else { readingCatalog = NSNull() }
        let recalled = try recalledReadings.map { index -> [String: Any] in
            guard let evidence else { throw ComputerUseBrowserLinkPlanError.inputChanged }
            return try evidence.recall(index, goal: goal)
        }
        var context: [String: Any] = ["version":allowsAnswer ? 8 : 5, "goal":goal.plannerContext,
            "page":try JSONSerialization.jsonObject(with: Data(candidates.readingInput.contextJSON.utf8)),
            "candidates":candidates.candidatePlannerContext, "navigation_history":visits,
            "reading_catalog":readingCatalog,
            "recallable_readings":recallableReadingIndices,
            "recalled_readings":recalled,
            "document_answer_source_status":candidates.documentAnswerSourceStatus.rawValue,
            "field_review":candidates.review.map { $0.plannerContext as Any } ?? NSNull(),
            "requirement_assessment":assessment.map { $0.plannerContext as Any } ?? NSNull()]
        if allowsAnswer {
            context["answer_candidate_indices"] = answerEligibility?.candidateIndices ?? []
            context["answer_counts"] = answerEligibility?.selectionCounts ?? []
            context["answer_options"] = answerEligibility?.plannerOptions ?? []
            context["observed_at_milliseconds"] = candidates.observedAtMilliseconds
            context["history_destinations"] = historyOptions.map { option in
                ["visit":option.visit, "mode":option.mode.rawValue,
                 "readings":evidence?.readingIndices(forSource: option.target.destinationIdentity) ?? []] as [String: Any]
            }
        }
        contextJSON = String(decoding: try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]), as: UTF8.self)
        let nativeEvidence = candidates.evidence
        bindingDigest = ComputerUseTaskContract.digest(["browser-link-selection-input-v1", goal.digest,
            nativeEvidence.document.contextID, String(nativeEvidence.document.generation), nativeEvidence.documentID, nativeEvidence.page.id, contextJSON]
            + choices.flatMap { [$0.candidateID, String($0.links.count)] + $0.links }
            + (candidates.answerSourcePolicy.map { ["answer-source-policy", $0.digest] } ?? [])
            + (assessment.map { ["requirement-assessment", $0.interpretationDigest] } ?? [])
            + (evidence.map { ["research-evidence", $0.digest] } ?? [])
            + history.flatMap { [$0.operationID, $0.goalRevision, $0.kind.rawValue] })
    }

    func resolve(candidate: Int, link: String) throws -> ComputerUseBrowserResearchTask.LinkChoice? {
        if candidate == -1, link.isEmpty { return nil }
        guard choices.indices.contains(candidate), choices[candidate].links.contains(link) else {
            throw ComputerUseBrowserLinkPlanError.invalidProposal
        }
        return .init(candidateID: choices[candidate].candidateID, linkID: link)
    }
    func resolveAnswer(indices: [Int]) throws -> ComputerUseBrowserResearchAnswer.Selection {
        guard allowsAnswer, let answerEligibility else { throw ComputerUseBrowserLinkPlanError.invalidProposal }
        return try answerEligibility.selection(indices)
    }
    func resolveHistory(visit: Int) throws -> ComputerUseBrowserHistoryOption {
        guard let option = historyOptions.first(where: { $0.visit == visit }) else { throw ComputerUseBrowserLinkPlanError.invalidProposal }
        return option
    }
    var description: String { "BrowserLinkSelectionInput(candidates: \(candidateCount))" }
    var debugDescription: String { description }
}

extension ComputerUseOwnedBrowser {
    func validateResearchAnswerBinding(_ answer: ComputerUseBrowserResearchAnswer, reading: ComputerUseBrowserResultCandidates,
                                      goal: ComputerUseBrowserGoalInput, evidence: ComputerUseBrowserResearchEvidence) throws {
        try Task.checkCancellation()
        try validateSourceDocument(reading.evidence.document)
        guard currentDocument(taskID: goal.taskID) == reading.evidence.document,
              let eligibility = try reading.answerEligibility(goal: goal, evidence: evidence, recalledReadings: answer.recalledReadings) else { throw ComputerUseBrowserError.pageChanged }
        try answer.validate(for: eligibility)
    }

    func prepareResearchAnswer(_ selection: ComputerUseBrowserResearchAnswer.Selection, reading: ComputerUseBrowserResultCandidates,
                               goal: ComputerUseBrowserGoalInput, policy: ComputerUseBrowserAnswerSourcePolicy,
                               evidence: ComputerUseBrowserResearchEvidence) async throws -> ComputerUseBrowserResearchAnswer {
        try await validateResultAnswerSource(reading, goal: goal, policy: policy)
        guard let eligibility = try reading.answerEligibility(goal: goal, evidence: evidence, recalledReadings: selection.recalledReadings) else { throw ComputerUseBrowserLinkPlanError.inputChanged }
        let answer = try eligibility.answer(for: selection)
        try await validateResultAnswerSource(reading, goal: goal, policy: policy)
        try Task.checkCancellation()
        return answer
    }

    /// Fresh observations for the user's progress update, without promoting
    /// model grouping, scalar comparisons or historical readings to success.
    func prepareResearchReport(_ batch: ComputerUseBrowserResultCandidates, goal: ComputerUseBrowserGoalInput,
                               policy: ComputerUseBrowserAnswerSourcePolicy) async throws -> ComputerUseBrowserResearchReport? {
        do {
            guard batch.documentAnswerSourceStatus == .permitted else { return nil }
            try await validateResultAnswerSource(batch, goal: goal, policy: policy)
            guard let interpretation = batch.goalInterpretation, interpretation.input == goal,
                  interpretation.disposition == .research, !batch.candidates.isEmpty else { return nil }
            let requirements = try interpretation.requirements.map { requirement -> String in
                guard let source = interpretation.source(of: requirement) else { throw ComputerUseBrowserResultError.goalChanged }
                return source
            }
            var passages: [ComputerUseBrowserResearchReport.Passage] = []
            for candidate in batch.candidates {
                let text = candidate.texts.map(\.text).joined(separator: "\n")
                var links: [String] = []
                for id in candidate.selectedLinkIDs.prefix(2) {
                    guard let native = batch.evidence.page.links.first(where: { $0.id == id }),
                          let url = URL(string: native.destination), policy.permitsEvidenceFrom(url),
                          let exported = ComputerUseBrowserResearchReport.reportableURL(url) else { continue }
                    // Verify this exact retained anchor and its destination.
                    // Preparation does not open it, submit a form or infer
                    // that its destination contains the quoted page passage.
                    do {
                        _ = try await prepareResultLinkNavigation(batch, candidateID: candidate.id, linkID: id, goal: goal)
                    } catch ComputerUseBrowserError.linkNavigationUnavailable { continue }
                      catch ComputerUseBrowserError.sourceNotAllowed { continue }
                    try Task.checkCancellation()
                    if !links.contains(exported) { links.append(exported) }
                }
                passages.append(.init(text: text, detailsLinks: links, omittedLinks: candidate.selectedLinkIDs.count - links.count))
            }
            let report = ComputerUseBrowserResearchReport(rootTaskID: goal.taskID, goalRevision: goal.digest, readingIdentity: batch.requirementAssessmentIdentity,
                site: ComputerUseBrowserSite.displayName(for: batch.evidence.document.committedURL),
                sourceLink: ComputerUseBrowserResearchReport.reportableURL(batch.evidence.document.committedURL),
                passages: passages, surroundingText: batch.surroundingTexts.map(\.text).joined(separator: "\n"),
                requirements: requirements, incompleteReading: batch.sourceTruncated || batch.omittedStructure
                    || batch.omittedEmbeddedContent || batch.omittedControls || batch.projectionOmittedRecords || !batch.evidence.page.controls.isEmpty
                    || batch.candidates.contains { !$0.unprojectedTextIDs.isEmpty || !$0.unprojectedLinkIDs.isEmpty })
            try await validateResultAnswerSource(batch, goal: goal, policy: policy)
            try Task.checkCancellation()
            return report
        } catch {
            // Retain the research owner's operation slot until any native
            // DOM callback outliving cancellation has actually finished.
            await joinDOMCompletion(document: batch.evidence.document)
            throw error
        }
    }

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
                                 answerPolicy: ComputerUseBrowserAnswerSourcePolicy? = nil,
                                 interpretation: ComputerUseBrowserGoalProposal? = nil,
                                 historyOptions: [ComputerUseBrowserHistoryOption] = []) async throws -> ComputerUseBrowserResultCandidates {
        try Task.checkCancellation()
        guard proposal.goalRevision == goal.digest, goal.taskID.utf8.elementsEqual(evidence.document.taskID.utf8),
              answerPolicy == nil || answerPolicy?.goalRevision == goal.digest,
              interpretation == nil || interpretation?.input == goal else {
            throw ComputerUseBrowserResultError.goalChanged
        }
        guard proposal.input.page == evidence.page else { throw ComputerUseBrowserResultError.invalidPage }
        guard historyOptions.allSatisfy({ $0.target.isBound(to: evidence) }) else { throw ComputerUseBrowserResultError.invalidPage }
        if let review = proposal.review {
            guard !review.hasRequirementMapping || interpretation != nil else { throw ComputerUseBrowserResultReviewError.inputChanged }
            try review.validate(for: ComputerUseBrowserResultReviewInput(goal: goal, page: proposal.input, proposal: proposal,
                interpretation: review.hasRequirementMapping ? interpretation : nil))
        }
        try await validatePageEvidence(evidence)
        try Task.checkCancellation()
        return .init(proposal: proposal, goal: goal, evidence: evidence, answerPolicy: answerPolicy, interpretation: interpretation, historyOptions: historyOptions)
    }

    /// Reuse requires the same review, complete goal and current native page.
    /// A valid model review still cannot certify an offer or task completion.
    func validateResultReview(_ review: ComputerUseBrowserResultReview, reading: ComputerUseBrowserResultCandidates,
                              goal: ComputerUseBrowserGoalInput) async throws {
        try Task.checkCancellation()
        guard reading.review == review else { throw ComputerUseBrowserResultReviewError.inputChanged }
        try await validateResultCandidates(reading, goal: goal)
        try Task.checkCancellation()
    }

    /// Assessment is a reading fact. Current native evidence and the exact
    /// retained interpretation are still required before using it again.
    func validateResultAssessment(_ assessment: ComputerUseBrowserResultAssessment, reading: ComputerUseBrowserResultCandidates,
                                  interpretation: ComputerUseBrowserGoalProposal) async throws {
        try Task.checkCancellation()
        guard reading.goalInterpretation == interpretation, assessment.interpretationDigest == interpretation.digest,
              reading.requirementAssessment == assessment else { throw ComputerUseBrowserResultError.goalChanged }
        try await validateResultCandidates(reading, goal: interpretation.input)
        try Task.checkCancellation()
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
        do {
            try await validatePageEvidence(batch.evidence)
            try Task.checkCancellation()
        } catch {
            // A timeout may win while WebKit still owns a validation callback.
            // Do not release the research operation until that work has joined.
            await joinDOMCompletion(document: batch.evidence.document)
            throw error
        }
    }
}
