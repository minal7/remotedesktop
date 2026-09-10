# Derived party totals for aggregate number fields

Source checkpoint: 2026-09-09. Parent: `9dfd8aa`. Source repair and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

“2 adults and 1 child” contains enough information to derive a total of three people. The preceding [party component repair](BROWSER_PARTY_CRITERION_COVERAGE_REVIEW.md) supplied only the two category values. A website offering a single People number field therefore had no supported native total to select. The model could not invent the number `3` through the literal-source path.

A total and a composition express different facts. Three people can satisfy the input format of an exploratory search without establishing that the provider accepts two adults and one child. Numeric equality also cannot preserve an old adult-field meaning after the proposed purpose changes to a total. This distinction belongs in native criterion accounting, independently of model choice.

## Form values and provenance

[Form input](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) now offers three normalized values for each complete, exact native adult/child party: adults, children and people. The people value is the bounded integer sum of the existing composition. It keeps the same party identity and includes every contributing requirement row, including splits inside numbers or units. Existing scalar source grouping and accepted-answer binding determine that composition; this change does not combine separate clauses, parties or trip legs.

The total uses the existing normalized number-input contract. It remains a people count, not a ticket count, result count or provider category. The existing [proposal boundary](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormProposal.swift) requires its complete source set to match any reviewed field intent. The native field contract still checks type, constraints, exact values, required objects, current ownership and proof/receipt history. Unsupported or bounded party language does not acquire an exact total through this addition.

Form context version 22 offers the new value and retains the date-term and date-replacement fields when present. The response shape is unchanged: planners select an offered normalized ID. [Instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormPlanner.swift) require a field whose meaning is the whole party's people count and retain the unresolved composition work after a total-only search. Field/provider meaning remains a model proposal requiring qualification.

## Separate total and category records

An explicit component predicate now identifies adult/child normalizations separately from the derived total. `party_criteria` continues to track exactly those two categories; the people value neither adds a third mandatory category nor supplies a missing adult/child record.

A verified total retains the ordinary field value, sources, native input or observation proof, and continuation obligations. It does not create a `party_component` record. When a later verified total replaces an earlier category purpose on the same field, existing continuation logic removes that category record even if the number is unchanged. Merely proposing the replacement does not remove anything.

The [continuation and historical projection](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) retain these distinctions. Existing continuation identity includes every party normalization, so the derived total participates in the digest through the existing counted value list. Historical `same_counts` compares the two required categories, rather than mistaking the additional total normalization for a changed composition. Old history still supplies no current field verification on a later document.

## Authored verification, unrun

Three new methods in the [form suite](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormPlannerTests.swift) specify:

- Whole-source totals across split rows, zero and upper-bound counts, separate party identities, absence of cross-clause aggregation, and withholding exact totals for bounds/continued ambiguous lists. A total creates no category record or completed coverage.
- An aggregate-only native form with either a differing or already-matching default. The authored path covers complete source provenance, coexistence with date terms, input versus observation-only proof, one exploratory GET query, unchanged complete goal and two still-missing category records in navigation history.
- A later total purpose removing an earlier adult record with the same number, using native value verification without another input event and retaining the actual input history.

Existing form, [clarification](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) and [scalar](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserScalarRequirementsTests.swift) expectations include the new total and complete source indices. Existing category-completion, changed-value, duplicate-record and historical-count cases continue to describe the separate component behavior.

Six changed Swift files pass parse-only checks. Default/focused source inventories select 1776 / 1093 methods, with three additions and no removals. Syntax and source registration do not establish compilation, assertions, model decisions, provider behavior or end-to-end correctness.

## Remaining repair order

1. Qualify field and provider semantics: number-input type alone does not prove “People,” adult/child ages or applicability to the selected event/trip. Select/custom passenger widgets retain their existing distinct capability paths.
2. Associate broader party requirements, ages/infants, separate answer counts and trip legs without discarding bounds or assuming unrelated groups belong together.
3. Complete explicit goal corrections and account/document recovery for prior criteria and uncertain actions. A matching total is no substitute for preserving those obligations.
4. Continue the [repair checklist](../../../TODO.md). The global navigation-source completion restriction stays active. Runtime and real travel/concert/movie tests remain deferred pending permission; model replacement, RTX 3080 adaptation and 8 GB resource qualification remain for their authorized stage.

No model/SSH activity, installed-app replacement, push or generated-file cleanup occurred here.
