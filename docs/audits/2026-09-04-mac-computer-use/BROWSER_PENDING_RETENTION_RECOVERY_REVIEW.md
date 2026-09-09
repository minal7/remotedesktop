# Recover changed criteria from a pending retention review

Source checkpoint: 2026-09-09. Parent: `4e609e9`. Source repair and prepared regressions only. Compilation, assertion execution, inference and live qualification remain paused.

## First-principles finding

A retain-only review carries two different facts: earlier native verification established desired criteria on original objects, and the current user request motivates keeping those criteria. If a website changes a value before the retention stage publishes, the current state no longer satisfies the retained criterion. That does not erase the original verification, desired value or current source purpose.

The previous implementation correctly refused to publish success, but its pending execution slot then prevented the action planner from proposing a repair. Replaying an input would be unjustified because the pending stage sent none. Dropping it and returning to the old stage would lose current source or preservation duties. The useful recovery is to retain those obligations explicitly as incomplete, after proving that their original native origins and preservation still hold.

## Source repair

The read-only class in [FormStage](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) now implements `recoverCriteriaForRepair`. It requires the original pending retention stage and current ownership. Candidate continuation construction retains the exact old desired values, verified target set, actual-input IDs and sources, observation proofs, current retain purposes, captured invariant values and explicit preservation.

Recovery restores the original reviewed page observation and scoped readings without rebinding fields to changed values. Original metadata/read obligations remain required. The existing native requirement inspector then validates original objects, actual input receipts or no-input proof origins, exact input ledger, nonrepairable captured invariants and preservation. Only previously verified, unpreserved criteria can be reported as changed.

A nonempty changed set permits publication of the candidate continuation and a receipt with `requiresRepairAtPublication=true`. That makes the historical stage incomplete even though it has no planned input steps. Actual input and new no-input verification counts stay zero. The retention count describes the current review's retained criteria, not the number of currently matching values. This operation performs no input, creates no journal and revokes no operation IDs.

An unchanged pending review returns no recovery result; it must still complete the normal full validation path. A completed request returns only its original historical receipt. Pause or retirement during native observation prevents publication and joins outstanding DOM completion. Handback requires a new observation and native inspection; cached state cannot complete the recovery.

The [owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) exposes `recoverPendingRetainedCriteria` only for a pending `ComputerUseBrowserRetainedFormStage` with the exact active goal. Physical input stages, unfinished preparation, pending navigation and unanswered questions cannot pass through this route. The normal history recorder retains the same stage and original adapter.

The [driver](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift) tries this route after eligible form failures before the existing physical-input history, prefix and unsent-retirement recovery paths. A successful recovery releases pending execution into action planning. Fresh action inspection identifies changed criteria; ordinary source-backed form planning must then explicitly repair them. It cannot copy hidden old bytes as an implicit input instruction, discard the current source purposes or query while values remain changed.

Existing version-22 [action context](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) already carries the separate retention count, historical repair flag and current per-criterion repair flags. Instructions now explain incomplete recovered retention explicitly. If the user restores the original desired value after recovery, fresh native inspection can permit a query without another input while the old receipt remains historically incomplete. History is not rewritten as current success.

## Prepared coverage and limited checks

Nine new methods in [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift) cover:

1. Incomplete recovery after either original input or no-input verification, with unchanged origins, desired values, counts and journal writes; later preparation must identify the changed field as repair work.
2. Driver continuation through only the required Query repair and a native fixture GET, preserving Category and prior history.
3. A newly accepted `Keep Seattle.` answer surviving recovery while the captured City value is Portland; the earlier actual-input sources, IDs and proof origins remain unchanged.
4. Pause at page observation and native inspection, refused work before handback and fresh reads after it.
5. Changed editable or readonly preservation, and replacement native objects, withholding publication.
6. Lost native ledgers refusing reconstruction for both input and observation origins.
7. A pending physical input stage receiving no result, command, journal write or status change from retention recovery.
8. An unchanged interrupted review declining repair recovery and completing through its normal validation path.
9. A later user-restored criterion allowing a fresh query with no repeated input and no rewrite of the historical repair flag.

The accepted-answer setup was extracted into a shared helper while keeping the previous source-continuity assertions. These are authored planner decisions and unrun assertions, not model-quality evidence.

Five changed Swift files passed syntax parsing only. The assembled DOM, five embedded fragments and 38 distinct fixture scripts/snippets passed JavaScript syntax checks only. The source inventories select **1,512 default** and **829 focused** methods, adding nine and removing none. Documentation targets and whitespace were checked. These results do not establish Swift type correctness or passing runtime behavior.

No build, typecheck, assertion execution, inference, app/browser/computer-use launch, SSH retry, held-out inspection, push or installed-app replacement occurred. No scratch artifact was retained.

## Remaining work

The subsequent [retained-caret repair](BROWSER_RETAINED_CARET_REVIEW.md) separates incidental selection movement from read-only criterion validation and establishes fresh selections for later edit revisions. The later [preparation-criteria recovery](BROWSER_PREPARATION_CRITERIA_RECOVERY_REVIEW.md) covers fully captured, unexecuted retention and planning. The list below records this checkpoint's earlier boundary; changes before a complete private capture and later physical-preparation recovery remain open.

- This path starts after an exact retention proposal is accepted into execution. Changes during still-pending preparation or model planning need a corresponding reviewed recovery path that keeps their original capture and semantic duties. They cannot be promoted to an accepted retention execution merely to reuse this method.
- The full preparation/unchanged-retention validator still compares entire text snapshots through `bindFields`, including caret selection. Review whether incidental selection changes should block a read-only criterion review, while keeping exact input preconditions and requested preservation. This checkpoint does not relax that check.
- Explicit supersession and changed goals remain open. This recovery keeps the desired criteria; it does not authorize removing obligations, reinterpreting a conflicting answer, replacing native objects or discarding uncertain input.
- Changed original scoped readings or required metadata still refuse restoration. Broader dependent-control and document/process recovery must reconcile those obligations explicitly.
- Continue account/login handoff, independent task/result verification and the other items in the [repair TODO](../../../TODO.md).
- Runtime qualification, actual lightweight model comparisons, the 8 GB Mac target and real travel/concert/movie scenarios remain deferred until explicit execution permission. Remote model adaptation remains an option after measured model failures and verified access.
