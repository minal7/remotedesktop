# Preserve a native party clause across model source partitions

Source checkpoint: 2026-09-09. Parent: `abe09c5`. Source repair and prepared coverage only. Builds, typechecking, assertions, app/browser execution and inference remain paused.

## First-principles findings

The [mixed-party repair](BROWSER_MIXED_PARTY_REQUIREMENTS_REVIEW.md) could evaluate a complete “2 adults and 1 child” clause, but its meaning still depended on the model putting the clause in one row. Separate rows could become independent quantities, losing the aggregate capacity check. Splitting a number from its unit could instead produce an unnecessary missing-unit question. A historical whole clause and a newly merged/split interpretation also needed a shared identity.

A model row is a source partition, not an independent semantic obligation merely because the model chose that boundary. Native grouping must keep the complete clause, preserve its exact occurrence, and retain the association among its components. Form input must still know which source fragments justify each specific value.

## Source changes

The [scalar compiler](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) recognizes exact party clauses over adjacent source rows within one user turn. Candidate windows are bounded to 2048 UTF-8 bytes and must parse the complete existing adult/child grammar. They cannot consume unrelated source text. A current interpretation needs positive condition rows, compatible relations and at least one quantity row; literal fragments may also use the `other` field. Accepted whole literal quantity answers and historically retained native clauses provide their existing separate authority for changed labels.

Every row covering one native party clause now carries the complete party predicate and the same ordered `sourceRequirementIDs`. Grouped condition identity includes these source IDs. The rows therefore cannot pass as unrelated adult, child, number or unit predicates. Equivalent windows that differ only at supported boundary whitespace/punctuation retain the same exact native source occurrence. Different occurrences remain separate.

Historical grouping reconstructs the same clause from the question-time interpretation. Exact old/new source spans and compositions must match. The historical row IDs are retained on the current group, and covered earlier component rows do not subsequently overwrite the group with independent scalar predicates. Other historical scalar conflicts remain effective. A damaged group is reconciled as a whole; no surviving member may conceal a failed member.

Overlapping party interpretations and continued adult/child lists remain unresolved. A separately labeled leading bound or negation, such as “at most” or “not,” also blocks treating the following party as an exact positive composition. This unresolved state is absorbing through ordinary historical scalar restoration. These guards cover the supported literal patterns; they are not a general natural-language modifier compiler.

Quantity-question matching treats a group as one associated clause. A question about an earlier component can still confirm it after rows merge; a question about the whole party applies atomically after rows split. Existing count/composition compatibility checks still apply. A newly supplied complete party answer may span multiple rows without replacing the earlier outcome or becoming unrelated quantities. All associated targets and dependent answer bindings remain unresolved together on conflict.

Native source meaning includes grouped and ambiguous party rows, independently of successful completion. A changed website label cannot turn their literal count meaning into a source policy. [Result assessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) keeps ambiguous groups uncompiled. Bound group members each receive the whole party's capacity comparison, including the additional people-capacity ceiling introduced in the preceding repair. Thus a child row cannot pass independently when adult capacity or the aggregate ceiling fails. Existing offer association, quotation meaning and navigation-history gates still apply.

[Form normalization](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) emits one adult/child value pair per native group. Component byte spans identify every current row contributing its number and unit. A normalized value retains its first `requirement` for the existing interface and includes `requirements` when its source spans multiple rows. Those inputs use context version 18. Ordinary single-source input shapes retain their previous versions.

The [form proposal boundary](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormProposal.swift) checks all of a normalized value's source indices against a declared edit intent and retains all of them in edit provenance. The [planner instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormPlanner.swift) explain that the first index is not the complete source list when `requirements` is present. This supplies source provenance for each edit; it does not certify that every party component has been entered across all form stages.

## Prepared coverage and permitted checks

Ten new methods are authored and unrun:

- Two [scalar methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserScalarRequirementsTests.swift) cover whole/component/inside-word boundaries, multibyte preceding text, component source indices, overlapping lists, positive-role requirements, bounds and negations.
- Four [clarification methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) cover historical split/merge recovery, atomic whole-group answers, a component confirmation after merging, new answers split across rows, changed source/prohibition labels and protection against historical restoration of a negated/bounded clause.
- One [assessment method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResultAssessmentTests.swift) prepares whole-party capacity and total-ceiling checks under three partitions, without spurious missing-unit questions.
- Two [form methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormPlannerTests.swift) cover complete number/unit source lists and the actual native owner path carrying them through two number-field edits and one query.
- One [answer method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift) prepares complete versus insufficient party eligibility under split source rows, requiring every member to retain the complete party result.

Ten changed Swift files pass parse-only syntax checks. Default/focused source inventories select 1690 / 1007 methods, with ten additions and no removals or renames. These checks do not establish type correctness, assertion outcomes or runtime behavior. No fixtures, app launches, local models, computer-use sessions or remote GPU jobs executed.

## Remaining work

This repair associates an exact joined literal clause. It does not infer relationships among arbitrary standalone sentences, different parties/trip legs, unrelated answer turns, or a larger model row that mixes the party with other meaning. General classification correction, modifier semantics, unsupported/ambiguous answers and explicit intent replacement remain open. Historical merges that include unrelated source text remain held.

Component-specific criterion coverage across form stages still needs native accounting: correct source provenance for one entered field is not proof that the entire party criterion is complete. Provider age categories, ages/infants, bounded groups, aggregate-only passenger controls, account/document recovery and complete model/host/client qualification also remain open. Continue the [repair checklist](../../../TODO.md); resource measurements and real travel/concert/movie tests await their authorized stage.
