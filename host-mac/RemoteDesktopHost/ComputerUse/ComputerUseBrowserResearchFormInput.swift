import Foundation

enum ComputerUseBrowserResearchFormError: Error, Equatable { case invalidInput, invalidProposal, inputChanged, contextLimit, stageLimit }

/// Source-bound control references selected before private field values are read.
struct ComputerUseBrowserControlPreservation: Equatable, Sendable {
    let controlID: String
    let requirementIndex: Int
}

/// Historical source bytes, independent of a later model's requirement IDs
/// and segmentation. A projection identifies overlap, not semantic equivalence.
struct ComputerUseBrowserFormSource: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let turn: Int
    let offset: Int
    let source: String
    let role: ComputerUseBrowserGoalProposal.Role
    let field: ComputerUseBrowserGoalProposal.Field

    init(index: Int, interpretation: ComputerUseBrowserGoalProposal) throws {
        guard interpretation.requirements.indices.contains(index),
              let source = interpretation.source(of: interpretation.requirements[index]) else { throw ComputerUseBrowserResearchFormError.invalidInput }
        let requirement = interpretation.requirements[index]
        turn = requirement.sourceTurnIndex; offset = requirement.sourceByteOffset; self.source = source
        role = requirement.role; field = requirement.field
    }

    func indices(in interpretation: ComputerUseBrowserGoalProposal) throws -> [Int] {
        guard interpretation.input.userTurns.indices.contains(turn) else { throw ComputerUseBrowserResearchFormError.inputChanged }
        let bytes = Array(interpretation.input.userTurns[turn].utf8), end = offset + source.utf8.count
        guard offset >= 0, end <= bytes.count, bytes[offset..<end].elementsEqual(source.utf8) else {
            throw ComputerUseBrowserResearchFormError.inputChanged
        }
        let indices = interpretation.requirements.indices.filter {
            let current = interpretation.requirements[$0]
            return current.sourceTurnIndex == turn && current.sourceByteOffset < end
                && offset < current.sourceByteOffset + current.sourceByteCount
        }
        guard !indices.isEmpty else { throw ComputerUseBrowserResearchFormError.inputChanged }
        return indices
    }

    func context(in interpretation: ComputerUseBrowserGoalProposal) throws -> [String: Any] {
        ["turn":turn, "sourceByteOffset":offset, "source":source, "role_at_edit":role.rawValue,
            "field_at_edit":field.rawValue, "requirements":try indices(in: interpretation)]
    }
    var description: String { "BrowserFormSource" }
    var debugDescription: String { description }
}

struct ComputerUseBrowserFormPreservationSource: Equatable, Sendable {
    let controlID: String
    let source: ComputerUseBrowserFormSource
}

/// An unfinished proposed edit, not permission to reuse a native target or
/// payload. A later plan must explicitly map it to a fresh source-backed edit.
struct ComputerUseBrowserFormPendingEdit: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let label: String
    let kind: String
    let sources: [ComputerUseBrowserFormSource]
    func context(in interpretation: ComputerUseBrowserGoalProposal) throws -> [String: Any] {
        ["label":label, "kind":kind, "sources":try sources.map { try $0.context(in: interpretation) }]
    }
    var description: String { "BrowserFormPendingEdit" }
    var debugDescription: String { description }
}

/// A completed native value with a proposed field meaning. This identifies
/// which goal component supplied the value, not provider/category semantics.
struct ComputerUseBrowserFormPartyCriterion: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let partySourceID: String
    let unit: String
    let value: String
    init?(_ normalized: ComputerUseBrowserResearchFormInput.Normalization) {
        guard normalized.kind == .partySize, let source = normalized.partySourceID,
              ["adults", "children"].contains(normalized.unit) else { return nil }
        partySourceID = source; unit = normalized.unit; value = normalized.value
    }
    var identity: [String] { [partySourceID, unit, value] }
    func context(partyAlias: String) -> [String: Any] { ["party":partyAlias, "unit":unit, "value":value] }
    var description: String { "BrowserFormPartyCriterion" }
    var debugDescription: String { description }
}

/// Coverage of intended structured counts. Missing/changed/duplicate records
/// cannot become full coverage through source-row overlap or numeric totals.
struct ComputerUseBrowserFormPartyCoverage: Equatable, Sendable {
    enum State: String, Sendable { case missing, recorded, changed, ambiguous }
    struct Component: Equatable, Sendable {
        let unit: String
        let value: String
        let state: State
        let targetIDs: [String]
    }
    let partySourceID: String
    let requirementIndices: [Int]
    let components: [Component]
    var allComponentsRecorded: Bool { components.count == 2 && Set(components.map(\.unit)) == ["adults", "children"] && components.allSatisfy { $0.state == .recorded } }
    func context(partyAlias: String) -> [String: Any] {
        ["party":partyAlias, "requirements":requirementIndices, "all_components_recorded":allComponentsRecorded,
         "components":components.map { ["unit":$0.unit, "value":$0.value, "state":$0.state.rawValue, "recorded_fields":$0.targetIDs.count] as [String: Any] }]
    }
    /// Context-local references never expose native task or target digests.
    static func aliases(for coverage: [Self], records: [String: ComputerUseBrowserFormPartyCriterion], historicalSources: [String] = []) -> [String: String] {
        var aliases: [String: String] = [:]
        for source in coverage.map(\.partySourceID) + historicalSources + records.keys.sorted().compactMap({ records[$0]?.partySourceID }) {
            if aliases[source] == nil { aliases[source] = "party\(aliases.count + 1)" }
        }
        return aliases
    }
    static func collect(normalizations: [ComputerUseBrowserResearchFormInput.Normalization],
                        records: [String: ComputerUseBrowserFormPartyCriterion], values: [String: String], changedTargets: Set<String> = []) -> [Self] {
        var seen: Set<String> = []
        return normalizations.compactMap { first in
            guard let sourceID = first.partySourceID, seen.insert(sourceID).inserted else { return nil }
            let required = normalizations.filter { $0.partySourceID == sourceID }
            let components = required.map { value -> Component in
                let targets = records.keys.filter { records[$0]?.partySourceID == sourceID && records[$0]?.unit == value.unit }.sorted()
                let state: State
                if targets.isEmpty { state = .missing }
                else if targets.count != 1 { state = .ambiguous }
                else if let target = targets.first, let record = records[target], !changedTargets.contains(target),
                        record.value.utf8.elementsEqual(value.value.utf8), values[target]?.utf8.elementsEqual(value.value.utf8) == true { state = .recorded }
                else { state = .changed }
                return .init(unit: value.unit, value: value.value, state: state, targetIDs: targets)
            }
            return .init(partySourceID: sourceID, requirementIndices: Set(required.flatMap(\.requirementIndices)).sorted(), components: components)
        }
    }
}

/// Proposal-only form context. Aliases describe native correspondence, not
/// permission to edit or submit. The original request and every accepted answer
/// remain intact; a later compiler must account for the remaining requirements.
struct ComputerUseBrowserResearchFormInput: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let interpretation: ComputerUseBrowserGoalProposal
    let evidence: ComputerUseBrowserFormEvidence
    let contextJSON: String
    let fieldAliases: [String]
    let editableFieldAliases: [String]
    let selectedFormID: String?
    let scopeReview: ComputerUseBrowserEffectScopeReview?
    let fieldIntentRequirements: [String: [Int]]
    /// Exact earlier verification purposes plus the current reviewed retain
    /// purposes. Captured invariants alone do not qualify as verified criteria.
    let retainedFieldSources: [String: [ComputerUseBrowserFormSource]]
    var isRetainOnly: Bool { editableFieldAliases.isEmpty && !retainedFieldSources.isEmpty }
    let requiredPreservation: [ComputerUseBrowserFormProposal.Preservation]
    let nativePreservation: ComputerUseBrowserFormPreservation?
    let nativePreservedSources: [ComputerUseBrowserFormPreservationSource]
    let requiredRepairFieldAliases: [String]
    let pendingEditAliases: [String]
    let previous: ComputerUseBrowserResearchFormContinuation?
    let preparationBaseline: ComputerUseBrowserFormPreparationBaseline?
    struct Normalization: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        enum Kind: String, Sendable { case date, partySize, ticketCount }
        let id: String
        let requirementIndex: Int
        let requirementIndices: [Int]
        let partySourceID: String?
        let kind: Kind
        let value: String
        let unit: String
        init(id: String, requirementIndex: Int, kind: Kind, value: String, unit: String, requirementIndices: [Int]? = nil, partySourceID: String? = nil) {
            self.id = id; self.requirementIndex = requirementIndex; self.kind = kind; self.value = value; self.unit = unit
            self.requirementIndices = requirementIndices ?? [requirementIndex]
            self.partySourceID = partySourceID
        }
        var description: String { "BrowserFormNormalization(kind: \(kind.rawValue))" }
        var debugDescription: String { description }
    }
    let normalizations: [Normalization]

    /// Only exact dates and explicit party/ticket counts have a scalar
    /// representation for these native input kinds. Ranges, maxima and counts
    /// of desired results cannot silently become an exact day or booking size.
    static func normalizations(for interpretation: ComputerUseBrowserGoalProposal) -> [Normalization] {
        let ledger = ComputerUseBrowserScalarRequirements(proposal: interpretation)
        var parties: Set<[String]> = [], dates: Set<[String]> = []
        return ledger.entries.enumerated().flatMap { index, entry -> [Normalization] in
            guard case .bound(let condition) = entry.resolution else { return [] }
            switch condition.predicate {
            case .day(let range):
                guard let day = range.lower, range.upper == day, range.lowerInclusive, range.upperInclusive,
                      dates.insert(condition.sourceRequirementIDs).inserted else { return [] }
                let indices = interpretation.requirements.indices.filter { condition.sourceRequirementIDs.contains(interpretation.requirements[$0].id) }
                guard indices.count == condition.sourceRequirementIDs.count, let primary = indices.first else { return [] }
                return [.init(id: "value\(index + 1)", requirementIndex: primary, kind: .date, value: day.iso8601,
                    unit: "civilDay", requirementIndices: indices)]
            case .party(let party):
                guard parties.insert(condition.sourceRequirementIDs).inserted else { return [] }
                return [(ComputerUseBrowserScalarRequirements.QuantityUnit.adults, party.adults), (.children, party.children)].compactMap { unit, count in
                    let indices = ledger.partyRequirementIndices(for: condition, unit: unit)
                    guard let primary = indices.first else { return nil }
                    return .init(id: "value\(index + 1)-\(unit.rawValue)", requirementIndex: primary, kind: .partySize, value: String(count), unit: unit.rawValue,
                        requirementIndices: indices, partySourceID: ledger.partySourceIdentity(for: condition))
                }
            case .quantity(.equal, let count, let unit):
                let kind: Normalization.Kind
                switch unit.scope {
                case .resultSet: return []
                case .ticketInventory: kind = .ticketCount
                case .party: kind = .partySize
                }
                return [.init(id: "value\(index + 1)", requirementIndex: index, kind: kind, value: String(count), unit: unit.rawValue)]
            default: return []
            }
        }
    }

    init(interpretation: ComputerUseBrowserGoalProposal, evidence: ComputerUseBrowserFormEvidence, selectedFormID: String? = nil,
         preservedControls: [ComputerUseBrowserControlPreservation] = [], previous: ComputerUseBrowserResearchFormContinuation? = nil,
         scopeReview: ComputerUseBrowserEffectScopeReview? = nil, nativePreservation: ComputerUseBrowserFormPreservation? = nil,
         preparationBaseline: ComputerUseBrowserFormPreparationBaseline? = nil) throws {
        guard interpretation.disposition == .research, !interpretation.hasUncompiledDateReplacements,
              interpretation.input.taskID.utf8.elementsEqual(evidence.page.document.taskID.utf8),
              (1...16).contains(evidence.fields.count), preservedControls.count <= 16,
              Set(preservedControls.map(\.controlID)).count == preservedControls.count else { throw ComputerUseBrowserResearchFormError.invalidInput }
        try preparationBaseline?.validate(interpretation: interpretation, evidence: evidence, formID: selectedFormID,
            review: scopeReview, previous: previous)
        if let scopeReview {
            let captured = preparationBaseline?.capturedControlIDs ?? []
            let inherited = Set(evidence.fields.filter { previous?.finalValues[$0.editable.snapshot.targetID] != nil }.map { $0.control.id })
            guard scopeReview.matches(interpretation: interpretation, evidence: evidence.page),
                  let scope = scopeReview.formScope, let selectedFormID, scope.formID == selectedFormID,
                  scope.preservedControls == preservedControls,
                  Set(evidence.fields.map { $0.control.id }) == Set(scope.discoveryControlIDs).union(captured).union(inherited),
                  scope.fieldIntents.allSatisfy({ intent in intent.disposition != .retain || evidence.fields.contains {
                      $0.control.id == intent.controlID && previous?.verifiedTargetIDs.contains($0.editable.snapshot.targetID) == true
                  } }) else { throw ComputerUseBrowserResearchFormError.inputChanged }
        }
        self.scopeReview = scopeReview
        let nativeIDs = scopeReview?.formScope?.nativePreservedControlIDs ?? []
        if let nativePreservation {
            guard !nativeIDs.isEmpty, nativePreservation.controlIDs == nativeIDs,
                  nativePreservation.scopeDigest == scopeReview?.formScope?.digest,
                  nativePreservation.document == evidence.page.document, nativePreservation.documentID == evidence.page.documentID,
                  Set(previous?.nativePreservation?.controlIDs ?? []).isSubset(of: Set(nativeIDs)) else {
                throw ComputerUseBrowserResearchFormError.inputChanged
            }
        } else if !nativeIDs.isEmpty || previous?.nativePreservation != nil {
            throw ComputerUseBrowserResearchFormError.inputChanged
        }
        self.nativePreservation = nativePreservation
        if let previous {
            guard previous.taskID == interpretation.input.taskID, previous.rootDigest == interpretation.input.rootDigest,
                  interpretation.input.continues(previous.goal), previous.formID == selectedFormID,
                  previous.document == evidence.page.document, previous.documentID == evidence.page.documentID,
                  previous.finalValues.allSatisfy({ id, value in
                      evidence.fields.contains { $0.editable.snapshot.targetID == id
                          && ($0.editable.snapshot.value.utf8.elementsEqual(value.utf8) || previous.repairableTargetIDs.contains(id)) }
                  }) else { throw ComputerUseBrowserResearchFormError.inputChanged }
        }
        var carriedControls = previous?.preservedControls ?? []
        for item in preparationBaseline?.preservedSources ?? [] {
            if let old = carriedControls.first(where: { $0.controlID == item.controlID }) {
                guard old.source == item.source else { throw ComputerUseBrowserResearchFormError.inputChanged }
            } else { carriedControls.append(item) }
        }
        for control in preservedControls {
            let source = try ComputerUseBrowserFormSource(index: control.requirementIndex, interpretation: interpretation)
            guard [.outcome, .condition, .prohibition].contains(source.role) else { throw ComputerUseBrowserResearchFormError.invalidInput }
            if let earlier = carriedControls.first(where: { $0.controlID == control.controlID }) {
                guard try earlier.source.indices(in: interpretation).contains(control.requirementIndex) else { throw ComputerUseBrowserResearchFormError.invalidInput }
            } else { carriedControls.append(.init(controlID: control.controlID, source: source)) }
        }
        let nativeSources = carriedControls.filter { nativeIDs.contains($0.controlID) }
        guard Set(nativeSources.map(\.controlID)) == Set(nativeIDs) else { throw ComputerUseBrowserResearchFormError.inputChanged }
        nativePreservedSources = nativeSources
        let serialized = try ComputerUseBrowserPlanningContext(page: evidence.page.page).serialized()
        guard let page = try JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [String: Any],
              let records = page["records"] as? [[String: Any]] else { throw ComputerUseBrowserResearchFormError.invalidInput }
        let projectedControls = Set(records.filter { $0["kind"] as? String == "control" }.compactMap { $0["id"] as? String })
        guard Set(evidence.fields.map { $0.control.id } + nativeIDs).isSubset(of: projectedControls) else {
            // An alias without its complete observed type/constraints/choices
            // would ask the planner to guess. Never trim a control to fit.
            throw ComputerUseBrowserResearchFormError.contextLimit
        }
        let aliases = evidence.fields.indices.map { "field\($0 + 1)" }
        let preserved: [ComputerUseBrowserFormProposal.Preservation] = try carriedControls.filter { !nativeIDs.contains($0.controlID) }.map { item in
            guard let index = evidence.fields.firstIndex(where: { $0.control.id == item.controlID }),
                  [.outcome, .condition, .prohibition].contains(item.source.role) else {
                throw ComputerUseBrowserResearchFormError.invalidInput
            }
            _ = try item.source.indices(in: interpretation)
            return .init(field: aliases[index], source: item.source)
        }
        let preservedIDs = Set(carriedControls.map(\.controlID))
        if let selectedFormID {
            guard evidence.fields.allSatisfy({ $0.control.form?.id == selectedFormID || preservedIDs.contains($0.control.id) }) else {
                throw ComputerUseBrowserResearchFormError.invalidInput
            }
        }
        let editable = zip(aliases, evidence.fields).compactMap { alias, field in
            !preservedIDs.contains(field.control.id) && (selectedFormID == nil || field.control.form?.id == selectedFormID)
                && (scopeReview == nil || scopeReview?.formScope?.fieldIntents.contains { $0.controlID == field.control.id && $0.disposition == .edit } == true) ? alias : nil
        }
        let intentRequirements = Dictionary(uniqueKeysWithValues: zip(aliases, evidence.fields).compactMap { alias, field -> (String, [Int])? in
            guard let intent = scopeReview?.formScope?.fieldIntents.first(where: { $0.controlID == field.control.id && $0.disposition == .edit }) else { return nil }
            return (alias, intent.requirementIndices)
        })
        fieldIntentRequirements = intentRequirements
        let supersededTargets = try previous?.supersededDateTargetIDs(in: interpretation) ?? []
        var retainedSources: [String: [ComputerUseBrowserFormSource]] = [:]
        for intent in scopeReview?.formScope?.fieldIntents ?? [] where intent.disposition == .retain {
            guard let index = evidence.fields.firstIndex(where: { $0.control.id == intent.controlID }),
                  let previous, previous.verifiedTargetIDs.contains(evidence.fields[index].editable.snapshot.targetID),
                  !supersededTargets.contains(evidence.fields[index].editable.snapshot.targetID),
                  var sources = previous.verifiedSources[evidence.fields[index].editable.snapshot.targetID], !sources.isEmpty,
                  let expected = previous.finalValues[evidence.fields[index].editable.snapshot.targetID],
                  expected.utf8.elementsEqual(evidence.fields[index].editable.snapshot.value.utf8) else {
                throw ComputerUseBrowserResearchFormError.inputChanged
            }
            for requirement in intent.requirementIndices {
                let source = try ComputerUseBrowserFormSource(index: requirement, interpretation: interpretation)
                if !sources.contains(source) { sources.append(source) }
            }
            retainedSources[aliases[index]] = sources
        }
        retainedFieldSources = retainedSources
        guard !editable.isEmpty || (!retainedSources.isEmpty && previous?.pendingEdits.isEmpty == true) else {
            throw ComputerUseBrowserResearchFormError.invalidInput
        }
        let repairs = zip(aliases, evidence.fields).compactMap { alias, field -> String? in
            if supersededTargets.contains(field.editable.snapshot.targetID) { return alias }
            if preparationBaseline?.refreshedTargetIDs.contains(field.editable.snapshot.targetID) == true { return alias }
            guard let value = previous?.finalValues[field.editable.snapshot.targetID],
                  !field.editable.snapshot.value.utf8.elementsEqual(value.utf8) else { return nil }
            return alias
        }
        guard Set(repairs).isSubset(of: Set(editable)) else { throw ComputerUseBrowserResearchFormError.inputChanged }
        let bindings = zip(aliases, evidence.fields).map {
            ["field":$0.0, "control":$0.1.control.id, "editable":editable.contains($0.0)] as [String: Any]
        }
        let requirements: [[String: Any]] = try interpretation.requirements.enumerated().map { index, requirement in
            guard let source = interpretation.source(of: requirement) else { throw ComputerUseBrowserResearchFormError.invalidInput }
            return ["index":index, "turn":requirement.sourceTurnIndex,
                "sourceByteOffset":requirement.sourceByteOffset, "sourceByteCount":requirement.sourceByteCount,
                "source":source, "role":requirement.role.rawValue, "field":requirement.field.rawValue,
                "relation":requirement.relation.rawValue, "values":requirement.values]
        }
        let normalized = Self.normalizations(for: interpretation)
        let partyCoverage = ComputerUseBrowserFormPartyCoverage.collect(normalizations: normalized, records: previous?.partyCriteria ?? [:],
            values: Dictionary(uniqueKeysWithValues: evidence.fields.map { ($0.editable.snapshot.targetID, $0.editable.snapshot.value) }))
        let partyAliases = ComputerUseBrowserFormPartyCoverage.aliases(for: partyCoverage, records: previous?.partyCriteria ?? [:])
        let priorEdits: [[String: Any]] = try zip(aliases, evidence.fields).compactMap { alias, field in
            guard let sources = previous?.verifiedSources[field.editable.snapshot.targetID] else { return nil }
            var row: [String: Any] = ["field":alias, "sources":try sources.map { try $0.context(in: interpretation) }, "requires_repair":repairs.contains(alias)]
            if let criterion = previous?.partyCriteria[field.editable.snapshot.targetID], let party = partyAliases[criterion.partySourceID] {
                row["party_component"] = criterion.context(partyAlias: party)
            }
            return row
        }
        let unfinished = previous?.pendingEdits ?? []
        let pendingAliases = unfinished.indices.map { "pending\($0 + 1)" }
        let pendingContext: [[String: Any]] = try zip(pendingAliases, unfinished).map { alias, edit in
            var row = try edit.context(in: interpretation)
            row["id"] = alias
            return row
        }
        var context: [String: Any] = ["version":scopeReview == nil ? 9 : (preparationBaseline == nil ? 12 : 13), "goal":interpretation.input.plannerContext,
            "selected_form":selectedFormID.map { $0 as Any } ?? NSNull(),
            "required_preservation":try preserved.map { ["field":$0.field, "source":try $0.source.context(in: interpretation)] as [String: Any] },
            "previous_edits":priorEdits,
            "required_repairs":repairs,
            "unfinished_edits":pendingContext,
            "current_goal_revision_at_previous_stage":previous.map { $0.goalRevision == interpretation.input.digest } ?? true,
            "requirements":requirements, "page":page, "field_bindings":bindings,
            "normalized_values":normalized.map { value -> [String: Any] in
                var row: [String: Any] = ["id":value.id, "requirement":value.requirementIndex,
                    "kind":value.kind.rawValue, "value":value.value, "unit":value.unit]
                if value.requirementIndices.count > 1 { row["requirements"] = value.requirementIndices }
                if let source = value.partySourceID, let party = partyAliases[source] { row["party"] = party }
                return row
            }]
        if scopeReview != nil {
            context["required_native_preservation"] = try nativeSources.map {
                ["control":$0.controlID,"source":try $0.source.context(in: interpretation)] as [String: Any]
            }
            context["scope_reviewed"] = true
            context["deferred_fields"] = scopeReview?.formScope?.fieldIntents.filter { $0.disposition == .deferred }.map(\.context) ?? []
            context["required_edit_intents"] = editable.map { ["field":$0, "requirements":intentRequirements[$0] ?? []] as [String: Any] }
        }
        if let preparationBaseline {
            context["previous_preparation"] = try preparationBaseline.reviewContext.context(in: interpretation)
            context["captured_unedited_fields"] = zip(aliases, evidence.fields).compactMap { alias, field in
                preparationBaseline.capturedTargetIDs.contains(field.editable.snapshot.targetID) && !editable.contains(alias) ? alias : nil
            }
        }
        if previous?.stateProofsByTarget.isEmpty == false {
            context["version"] = 14
            context.removeValue(forKey: "previous_edits")
            context["previous_criteria"] = priorEdits.map { row in
                var row = row
                if let alias = row["field"] as? String, let index = aliases.firstIndex(of: alias) {
                    row["verified_without_input"] = previous?.stateProofsByTarget[evidence.fields[index].editable.snapshot.targetID] != nil
                }
                return row
            }
        }
        if !retainedSources.isEmpty {
            context["version"] = 15
            context["retained_criteria"] = try retainedSources.keys.sorted().map { alias in
                ["field":alias,"sources":try retainedSources[alias]!.map { try $0.context(in: interpretation) }] as [String: Any]
            }
        }
        if editable.isEmpty { context["version"] = 16; context["retain_only"] = true }
        let refreshedAliases = zip(aliases, evidence.fields).compactMap { alias, field in
            preparationBaseline?.refreshedTargetIDs.contains(field.editable.snapshot.targetID) == true ? alias : nil
        }
        if !refreshedAliases.isEmpty { context["version"] = 17; context["refreshed_edit_fields"] = refreshedAliases }
        if normalized.contains(where: { $0.requirementIndices.count > 1 }) { context["version"] = 18 }
        if !partyCoverage.isEmpty || previous?.partyCriteria.isEmpty == false {
            context["version"] = 19
            context["party_criteria"] = partyCoverage.map { $0.context(partyAlias: partyAliases[$0.partySourceID]!) }
        }
        let dateReplacements = interpretation.dateReplacementContexts
        if !dateReplacements.isEmpty {
            context["version"] = 20
            context["date_replacements"] = dateReplacements.map(\.context)
            let retired = interpretation.retiredTaskPurposeRequirementIDs
            context["retired_task_purpose_requirements"] = interpretation.requirements.indices.filter { retired.contains(interpretation.requirements[$0].id) }
        }
        contextJSON = String(decoding: try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]), as: UTF8.self)
        self.interpretation = interpretation; self.evidence = evidence; fieldAliases = aliases
        normalizations = normalized; editableFieldAliases = editable; self.selectedFormID = selectedFormID
        requiredPreservation = preserved
        requiredRepairFieldAliases = repairs
        pendingEditAliases = pendingAliases
        self.previous = previous
        self.preparationBaseline = preparationBaseline
    }

    /// Resolve only an offered reference in this immutable input. Execution
    /// still requires owner revalidation and a separately compiled contract.
    func field(for alias: String) throws -> ComputerUseBrowserFormEvidence.Field {
        guard let index = fieldAliases.firstIndex(where: { $0.utf8.elementsEqual(alias.utf8) }) else {
            throw ComputerUseBrowserResearchFormError.invalidInput
        }
        return evidence.fields[index]
    }

    var description: String { "BrowserResearchFormInput(fields: \(fieldAliases.count))" }
    var debugDescription: String { description }
}
