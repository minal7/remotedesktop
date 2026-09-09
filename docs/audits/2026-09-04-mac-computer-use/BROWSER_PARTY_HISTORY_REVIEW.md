# Historical party criteria after form navigation

Source repair; execution pending. This extends the [retained form component repair](BROWSER_PARTY_CRITERION_COVERAGE_REVIEW.md). No test, browser, app, model or GPU workload executed.

## First-principles defect

A task spans pages; a native field binding belongs to one document. The app must remember what happened without confusing that memory with present authority. After an exploratory query for “2 adults and 1 child,” losing the missing child criterion can derail later planning. Reusing the old adult field receipt on a newly loaded form is equally wrong, even if the labels and numbers look identical.

The preceding repair kept component records inside the current native form continuation. Existing `form_history` retained stage counts after navigation, but not the normalized categories or incomplete party setup. On a later page without an editable form, the runtime could also select its default result-reading path without presenting those outstanding component records to the planner.

## Source changes

The [form history snapshot](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) is constructed only from a published native receipt and its corresponding continuation. It records the exact original goal revision, browser session identity, continuation digest, original party source fragments, expected component counts and the number/state of recorded components at that stage. It contains no native target, control, query or input capability.

The [research owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) captures this snapshot alongside confirmed form history. Duplicate publication must match the earlier receipt and snapshot. Navigation and later form stages retain it; retiring the owner clears it. Non-party stages have no snapshot. These records remain bounded by the existing 32-stage history limit.

[Action context](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) version 25 attaches `party_criteria_at_stage` to its original `form_history` row. The input boundary requires unique, ordered snapshots, corresponding confirmed receipts, the same browser session and an exact ancestor of the current accepted-answer sequence. A snapshot cannot be imported merely because another task/browser has the same prompt and field values.

Each historical row explicitly says `historical=true` and `current_field_verification=false`. Component counts and states are frozen at that stage. Current native normalization separately reports whether the same counts still compile, have changed, or are unresolved. Historical source fragments project onto current requirement rows without rewriting the old counts or their meaning. A published repair obligation remains identified by `required_repair_when_recorded`.

Context-local `party1`-style aliases connect current requirements and historical snapshots while native digests and session/target identities stay private. A snapshot is accumulated coverage on one form at one stage; snapshots must not be summed or pooled across documents to invent a complete setup. Fresh fields require fresh review and native verification.

The action input marks this history as requiring a planning decision, so the runtime's existing no-decision shortcut cannot bypass it. The relevant instructions are included even on a page without editable fields. Output alternatives and response schemas are unchanged; this adds task context, not another action capability or a completion path.

## Prepared coverage and permitted checks

Three new [form test methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormPlannerTests.swift) are authored and unrun:

- An exploratory query loads an identical-looking form with matching defaults. The new document starts without the old continuation, both components need fresh verification, and earlier input IDs do not transfer. Both historical snapshots remain separately available until owner retirement.
- A real native snapshot cannot be attached to a foreign browser session, a missing receipt or duplicate history entries.
- A scoped compatible or contradictory answer reparses the party into different requirement rows. History retains its original counts and missing child record while the current native requirement becomes `same_counts` or `unresolved`; the old snapshot never becomes current field verification.

Existing partial-query and sequential-stage tests are extended to inspect the actual owner history, the post-navigation action context, public aliases, absence of native identities, required planner instructions and distinct snapshots. Five changed Swift files pass parse-only checks. Default/focused source inventories select 1699 / 1016 methods, with three additions and no removals.

These checks establish source syntax and inventory consistency only. No typechecking, assertions, native fixtures, live websites, model inference or login sessions ran.

## Remaining work

This history is retained by the live research owner; it is not durable task recovery after process replacement. Browser session changes cannot import it. Login handoff still needs its full control, document recovery and credential privacy qualification. Historical source/field meaning remains distinct from native count/value checks, and provider age categories remain unproved.

Define explicit operation intent and native goal completion rules for partial exploration versus complete search setup. Continue the general requirement compiler, provider-field semantics, unsupported party formats, document/account recovery and durable ordered history. Keep the global navigation-source completion gate disabled until its complete qualification is available. The [repair checklist](../../../TODO.md) remains active, and all deferred execution still requires its authorized stage.
