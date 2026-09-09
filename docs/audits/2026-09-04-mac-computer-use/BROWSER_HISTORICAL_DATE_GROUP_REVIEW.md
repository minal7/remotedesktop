# Complete historical date clauses across source partitions

Source repair; execution pending. This follows [explicit date replacement](BROWSER_EXPLICIT_DATE_REPLACEMENT_REVIEW.md). No build, typecheck, assertion, app, browser, model or account-login execution occurred.

The subsequent [answer date-context repair](BROWSER_ANSWER_DATE_CONTEXT_REVIEW.md) gives each accepted answer its own fixed reference while preserving the original request's clock. The counts and remaining-work notes below describe this earlier checkpoint.

## First-principles finding

A requirement's meaning belongs to its complete source occurrence, not the number of rows a model produces. The prior checkpoint could retain or replace one intact original date row, but splitting that same row made its historical meaning uncompiled. For example, a previously recognized `before 2026-10-16` could become `before ` and `2026-10-16`. Its exact original text and user answer still existed, yet a legitimate date replacement could no longer reach form repair or answer eligibility.

Treating the shorter date as independent would be worse: it would discard the comparator. The repair reconstructs the complete previously recognized clause and keeps its identity separate from both another date occurrence and a later replacement answer.

## Native reconstruction

The [scalar ledger](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) now groups original-request date clauses from retained question-time interpretations. Admission needs an earlier native calendar date/range or known weekday clause. Current rows must be contiguous, reproduce the complete normalized clause and occupy its exact original byte position. The existing boundary normalization permits surrounding whitespace, sentence punctuation and a leading conjunction; it does not remove a date modifier or an unrelated condition.

Each current row carries the whole native predicate and the complete list of contributing source IDs. Weekday uncertainty remains uncertainty. An exact resolved civil date normalizes once with every source reference. A range or before/after bound cannot become an exact date input merely because one row contains its endpoint.

The earliest recognized complete occurrence controls later date-labelled fragments contained within it. Those fragments remain historical source records; they cannot narrow the earlier range or remove `next`, `this`, `before` or `after`. Overlapping expansions that require a new semantic interpretation remain unresolved. Rejoining exactly the same complete clause is supported, including after a question was issued against several rows.

Grouped rows reconcile atomically before and after clarification processing. A conflicting or uncompiled part cannot leave another part with a usable exact-date normalization. Native date source meaning also remains independent of current location, quantity, source or prohibition labels.

## Questions, replacement and existing effects

Both ordinary date and explicit replacement questions must cover every row of the native date unit. The live question retains the original source text and position. Historical question scopes are reconciled through complete byte coverage, so splitting or rejoining rows after an answer cannot lose an internal separator, endpoint or modifier. A partial question remains invalid.

Two separate occurrences with the same date remain separate origins. An ordinary confirmation can retain its application to both. Replacing one retires only that occurrence and preserves the other portion of the shared confirmation. The replacement still requires the separate visible question and authenticated user answer introduced by the preceding repair.

The eight-source-reference limit remains enforced. A nine-row unit cannot be shortened to make a question fit; the planner must provide a valid complete source partition. This patch does not increase conversation or prompt budgets.

Existing [form source records](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) map old source intervals onto the reconstructed current rows. Consequently, an unchanged physical value entered for a replaced date still requires a fresh stage. Previous input receipts, query attempts and preservation duties are retained. The [form planner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormPlanner.swift), [action planner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) and [goal planner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalPlanner.swift) now describe whole historical date units as well as introduced date answers. Existing context and normalization schemas already carry complete source lists; no new model capability is implied.

## Authored verification, unrun

Seven new methods are registered:

- Five [clarification methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) cover exact dates, before bounds, relative weekdays and ranges split after replacement; complete weekday confirmation and normalization; later endpoint labels followed by rejoining; separate identical date occurrences with a shared confirmation; and rejection of unrelated merged meaning or an oversized question scope. The prior weekday-repartition method now expects preserved whole-clause ambiguity when reconstruction is exact, while unrelated merging remains unresolved.
- One [form method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormPlannerTests.swift) extends the prior stale-criterion scenario with an original date split after the user replaces it. The old receipt must remain recorded, old-date queries unavailable, unrelated preservation retained, and a fresh corrected date stage required before a query.
- One [driver/answer method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift) extends the prior conflict/replacement scenario with a split original date before the explicit replacement question. Native answer eligibility must still require both the new date and the unchanged budget; wrong-date and excessive-price variants remain ineligible.

Seven changed Swift files pass parse-only checks. The default/focused source inventories select 1743 / 1060 methods, with seven additions and no removals. These are syntax and source-registration checks, not compilation, assertion or workflow evidence.

## Remaining work

This repair requires a previously recognized complete date clause in the original request. Initial unsupported partitions, arbitrary semantic reclassification, conditional or negated clauses, and merged date-plus-other duties still need the broader goal compiler. Trip-leg, provider and offer associations are not inferred from matching date values. General correction of budgets, quantities, locations and source policy remains open, as do longer conversations, direct steering, later relative-answer time origins and document/account recovery.

The [repair checklist](../../../TODO.md) remains active. Global navigation-source completion is still restricted. Real-site travel/concert/movie and login-handoff qualification remains deferred until explicit permission. No alternate model, SSH work, distillation, pruning or installed-app replacement occurred here.
