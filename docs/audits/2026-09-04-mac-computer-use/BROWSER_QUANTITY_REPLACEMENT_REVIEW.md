# Explicit quantity corrections in retained browser tasks

Source repair; execution pending. This extends the [explicit date replacement design](BROWSER_EXPLICIT_DATE_REPLACEMENT_REVIEW.md). No build, typecheck, assertion, app, browser, model, login or SSH execution occurred.

## First-principles finding

A retained request must allow the user to correct it. The existing ordinary quantity question could confirm `2 tickets` or supply a missing unit, but an answer of `3 tickets` became a contradiction. Treating the newest number as authoritative would have a different defect: it could silently erase a result count, party composition, bound or unrelated requirement.

A correction needs an explicit scope and dependency history. The original source stays in the request. A native question identifies the whole count being replaced; its accepted answer creates the new obligation. Entered browser values remain historical facts until a fresh plan verifies them against the active requirement. A corrected count does not establish ticket availability or relax the original price, date, location or source restrictions.

## Implemented scope

The [clarification boundary](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalClarification.swift) now exposes `replaceQuantity` with fixed user-visible text. It asks for the count and the same unit, explains that the whole count/comparator will be replaced, and states that other requirements stay in place. Selecting this topic alone changes nothing. Existing controller/session references, expiry, exact answer bytes and retained source clocks still apply.

The [native scalar ledger](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) admits one known scalar quantity origin. Supported units retain their distinct meaning: result count, ticket inventory or a scalar party count. A complete answer such as `three tickets`, `at least 3 tickets` or `make that three tickets` must retain the origin's unit. Bare counts, unit-only answers, changed units, compound instructions and negated or conditional answers cannot complete a replacement. The optional `make that` prefix is recognized only in this explicit correction answer; it is not an unscoped command channel.

Whole historical scalar clauses keep their native meaning after model relabeling. A complete replacement answer may be split across source rows; every fragment belongs to the same active quantity. Repeated corrections retain the intermediate links rather than flattening the old history into the newest answer. Ordinary confirmation after a split replacement preserves the complete source group.

An ordinary conflicting answer can point back to its original count when it retains that unit. A later explicit replacement retires that conflict along with the selected count. A conflicting answer in a different unit does not gain that lineage and remains unresolved after the original count changes. For example, replacing a ticket count cannot silently discard an earlier answer about three results.

Adult/child compositions, two separate origins and a confirmation shared by multiple origins do not acquire this replacement authority. These cases need a richer correction flow. Unknown original units must first be clarified. Arbitrary root-source splitting or merging that no longer identifies the whole original scalar remains unresolved; a quantity label cannot create a new native origin.

## Search, form and answer dependencies

The [goal proposal](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalPlanner.swift) distinguishes date and quantity supersession records and exposes a common uncompiled-replacement guard. A malformed replacement cannot authorize new task-purpose payloads. Retired sources remain recordable as history but cannot justify new search terms, field intentions, selections or private reads.

[Search context](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserSearchPlanner.swift) version 4 and [action context](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) version 32 expose quantity replacement links and compilation state when needed. [Form context](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) version 24 includes the links and retired purposes. Exact normalized quantities now carry their entire source group and appear once per group. Model instructions explain the scope and require active replacement sources. These are context additions, not changes to the existing wire answer reference format.

The [form continuation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) now checks superseded task sources for both correction types. An unchanged field previously justified by the old count still needs repair. Existing receipts, preserved fields and pending-input obligations survive. The [owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) and [form navigation stage](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormNavigation.swift) apply the same check before query preparation or dispatch.

[Result assessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) version 16 adds `quantityRequirementSuperseded` and the retained replacement graph. [Answer eligibility](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchAnswer.swift) accepts that status only for a matching native supersession record. Every active replacement row still needs its own result evidence. Ticket inventory uses capacity semantics; result counts and party quantities keep their own scopes. Supersession is evidence of the user's change, not a page fact.

## Authored verification, unrun

Ten new methods are registered in the active default and focused inventories:

- Eight [clarification methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) specify fixed question meaning, comparator replacement, unchanged dates/budget/prohibition, historical source relabeling, malformed answers, different units, shared confirmations, successive split replacements and whole-source normalization after confirmation.
- One [form method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormPlannerTests.swift) extends the existing native fixture to a number input: preserve the old receipt and unrelated private reference, prevent submission of the retired count, repair with the new source, and expect one query with three tickets and none with two.
- One [driver/answer method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift) extends the existing retained-question fixture: an ordinary three-ticket answer conflicts with two tickets, a separate explicit replacement question precedes browsing, and answer eligibility requires sufficient capacity together with the unchanged budget. Insufficient capacity and an excessive price must remain ineligible.

Sixteen changed Swift files pass parse-only checks. Active inventories select 1819 default / 1136 focused methods, with ten additions and no removals. These establish syntax and source registration only. None of the authored assertions, callback counts, model decisions or result outcomes has executed.

## Remaining repair sequence

1. Add well-scoped corrections for adult/child breakdowns, shared count origins, unit changes, locations, prices and source policies. Retain unaffected branches and require explicit meaning for totals versus components.
2. Handle arbitrary historical quantity source partitions and broader natural-language corrections. The current native grammar is bounded; it does not establish general understanding of ticket or travel requests.
3. Support direct steering and longer retained conversations without truncating earlier requirements. Existing four-user-turn/eight-scope-reference limits remain. A malformed replacement remains uncompiled even if a later answer changes another clause; no automatic deletion repairs that history.
4. Qualify form and answer fixtures, account handoff, provider semantics and global navigation-source history at the authorized execution stage. Source-history completion remains restricted; this patch does not release that gate.
5. Continue active-work progress detection, durable recovery and the rest of the [repair checklist](../../../TODO.md). Model competence, thermal behavior and the 8 GB Mac target remain unqualified. Alternate models and RTX 3080 adaptation remain available for a later measured need; no model comparison, distillation, pruning or new SSH attempt occurred here.

Real travel, concert, movie and login-handoff tests remain deferred until explicit permission.

The follow-up [whole-party correction repair](BROWSER_PARTY_REPLACEMENT_REVIEW.md) adds a separate explicit topic for replacing both adult/child counts. It also corrects the scalar-ticket form fixture's stale field label. Shared origins, inferred component changes and actual execution remain unqualified.
