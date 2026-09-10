# Party components across retained form stages

Source repair; execution pending. This follows the [party source-group repair](BROWSER_PARTY_SOURCE_GROUP_REVIEW.md). No model, browser, app or GPU workload ran for this repair.

Follow-up: the [derived party-total repair](BROWSER_PARTY_TOTAL_FORM_REVIEW.md) adds a people value for aggregate number fields while keeping the two category records separate. Form context advances to version 22; a verified total does not complete either category.

## First-principles defect

For “2 adults and 1 child,” three different facts must remain separate: the user's requested composition, the website field a planner proposes for each component, and the native observation or input receipt proving that field's value. An adult field containing `2` establishes neither a child field containing `1` nor the provider's interpretation of either category.

The earlier continuation retained values, exact source fragments and proof origins. It did not retain the normalized category used for each field. Both categories could refer to one source row, so source overlap could not distinguish a recorded adult criterion from a still-missing child criterion. A completed one-edit stage also described completion of its own plan, not completeness of the party setup. Replacing the model cannot repair this missing native state.

## Source changes

The [scalar ledger](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) derives a party identity from the task root and the exact native clause's turn, byte range and text. Native grouping makes that identity independent of model row boundaries. When a native group is unavailable, an exact scalar source span is used; an unavailable span falls back conservatively to the revision-bound condition identity. The composition is checked separately from this source identity.

The [form continuation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) now records the source identity, unit and value for each verified normalized adult/child criterion. Only completed input or native state verification creates or replaces a record. Unfinished edits and captured invariants do not. A later completed criterion with a different purpose removes the earlier party record even when the number is unchanged. Retain-only stages preserve existing records and their proof origins without inventing another component.

The [coverage projection](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) compares those records with both components of each current native party requirement:

| State | Meaning |
| --- | --- |
| `missing` | No completed criterion records this source and category. |
| `recorded` | Exactly one record has the expected count and its checked value agrees. |
| `changed` | The recorded or checked value differs, is absent, or native inspection reports a change. |
| `ambiguous` | Multiple fields record the same source and category; their values are not pooled. |

`all_components_recorded` requires both distinct categories to be recorded. It does not certify field meaning, provider age rules, availability, bookability or completion of the user's goal. Standalone quantities, unsupported party formats and unresolved requirements are outside this projection; an empty list is not a completed goal.

Form context version 19 includes `party_criteria`, component references in previous criteria, and party references on normalized values. [Action context](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) version 24 recomputes coverage against the current interpretation and native changed-target inspection. Public `party1`-style aliases join these rows within one context; task/source digests and private target IDs remain host-side. The [form instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormPlanner.swift) and action instructions explain the distinction between recorded components and task fulfillment.

Continuation digest version 9, or retained-continuation version 2, binds the expected components and per-target records. Existing [native query requirements](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) already incorporate that continuation digest and retain their value, object and receipt checks. Older non-party continuation shapes retain their previous digest versions.

Incomplete party coverage does not globally block exploratory queries. A location/category search may lead to a later form with more criteria. The current query capability remains a verified native GET operation; it does not certify the search as a complete party setup or introduce another submission mechanism.

## Prepared coverage and permitted checks

Six new [form test methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormPlannerTests.swift) are authored and unrun. They cover source repartition and task-root isolation; missing, duplicate and changed component records; a completed adult stage followed by verification of an untouched matching child default; observation-only and mixed observation/input completion; invalidation when a later criterion changes purpose without changing its number; and an exploratory query with one component still missing. The owner-path fixtures use the actual native form continuation, receipt and query APIs when eventually executed. Context assertions also check public aliases and absence of native identities.

An existing [clarification test](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) is extended to check stable party identity and component coverage across a scoped answer, source repartition and model role relabeling. Existing source-provenance context expectations now account for version 19.

Seven Swift files pass parse-only syntax checks. The maintained default/focused source inventories select 1696 / 1013 methods, with six additions and no removals. These are source checks, not typechecking or assertion results. Builds, fixtures, model inference, live websites, computer use and remote training remain paused.

## Ordered remaining repairs

1. Establish field/category semantics separately from numeric value verification. A model's choice of a normalized value remains a proposed field meaning; numeric input type and exact value alone cannot validate provider age categories.
2. Carry component records and outstanding obligations into navigation history and document/login recovery. This repair covers the same retained native form. Current form history does not expose this structured coverage after leaving that document, and old records must never authorize new document objects.
3. Define explicit stage and query intent for partial exploration versus a complete search setup. Apply native completion requirements to the appropriate operation instead of globally blocking every partial query or interpreting every completed stage as fulfillment.
4. Generalize the requirement ledger to unsupported party formats, multiple parties/trip legs, ages/infants, aggregate controls, new conditions and explicit intent replacement. Missing normalization must remain uncertainty.
5. Qualify retained-only and interrupted-prefix paths, goal revision, changed objects/values, context budgets and durable query identity when execution is authorized. Parse-only checks cannot establish their runtime behavior.
6. Complete the broader [repair checklist](../../../TODO.md), then perform the deferred bounded model/resource qualification and real travel, concert and movie scenarios with explicit permission. Global navigation-source completion remains disabled; this patch does not qualify full natural-language browsing or login handoff.
