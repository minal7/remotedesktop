# Recovering fully dispatched form history for criterion repair

Source checkpoint: 2026-09-09. Parent: `deab4b4`. Source implementation and prepared regressions; compilation, assertions and actual-model qualification remain paused.

## First-principles problem

Input history and current task satisfaction are different facts. Entering City can trigger a site handler that resets Query. Category and City may both have native dispatch receipts, and every physical input step may already be verified on disk, while an earlier criterion no longer matches its requested value. Repeating the whole form would duplicate successful input. Calling the stage complete would conceal the remaining repair.

The [observed-prefix checkpoint](BROWSER_OBSERVED_PREFIX_RECOVERY_REVIEW.md) retains observations before an unsent remainder. A fully dispatched input sequence has no unsent remainder, so it cannot use suffix revocation. The existing proper-prefix interface rejected this full-history case and left the original stage pending.

## Source repair

[ResearchFormStage](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) now has a separate `retainCompletedInputHistory` operation. It requires every physical step verified in the exact unretired journal, acquires that journal's execution lease and reconstructs historical requirements without running the text task. Mixed stages still require their retained native observation proof. Disk flags alone cannot recreate missing native origins.

The operation confirms the loaded journal's durability, observes the original document and invokes the native criterion inspector against the exact historical continuation. That inspection independently validates the original input receipts, required objects, preservation and any observation origins; only designated editable criteria may differ. It returns the currently changed criteria as repair work. A second exact journal/durability confirmation precedes publication. No input is replayed, no status is rewritten and no nonexistent suffix is revoked. Cancellation joins the pending native callback; a later attempt must inspect freshly.

The receipt now has `requiresRepairAtPublication`. If any criterion differed during recovery, `isCompleteStage` is false even when input and observation counts add up to the original plan. The receipt retains historical input/observation counts, while the continuation retains original desired values and source purposes. It does not adopt the changed field value as success. If fresh inspection finds all criteria correct, the recovered receipt can be complete. Neither result completes the research goal.

The [owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) publishes this history through its existing exact-stage/goal checks. The [driver](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift) attempts full-history recovery before proper-prefix or whole-unsent retirement when an eligible form error occurs. Partial or uncertain input flags cannot enter full-history recovery. Their original reconciliation and proven-unsent paths remain in force.

## Planner and query semantics

[Action context/schema version 21](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) distinguishes the new history from a fully satisfied stage. It uses `verified_form_stage.criteria`, retains actual input and observation counts, and includes `required_repair_when_recorded` in the current stage and history entries. `complete_stage=false` can now mean pending unsent work or a fully dispatched stage that required criterion repair. An empty `unfinished_edits` list therefore does not imply success.

The recorded repair flag is historical. Fresh per-criterion `requires_repair` values determine what currently needs work, and query controls remain withheld while those current repairs exist. A new form stage must supply a current source-bound repair for the changed criterion. If the user restores the original desired value on the same required object before later inspection, the old historical repair flag does not force redundant input. Query execution still performs its ordinary native revalidation.

The new context instructions remain present when the recovery history is carried to a page without an editable form. Existing context/schema versions are retained when no receipt required repair at publication. No output capability or generic text-task completion rule was relaxed.

## Prepared coverage and limited validation

Eight methods were added to [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift). They cover both mixed and input-only histories; explicit repair of only the changed Query criterion; v21 context/request construction; driver recovery when the City input handler resets Query; Pause during native history inspection and single publication after handback; lost native ledger; changed preservation and replaced required objects; a journal removed during inspection; matching current criteria; and criteria restored after an earlier repair-required receipt. An existing uncertain-input case also checks that attempted input cannot become full history.

The direct driver fixture prepares Query/Category/City, verifies the initially matching Query without input, sends Category and City, then has the City input event reset Query. Its authored planner must recover the two actual inputs, repair Query once and reach the explicit GET query. Other fixtures pause after all verified writes to exercise recovery boundaries independently. These assertions are prepared, not executed, and use authored model decisions rather than a local model.

Five changed Swift files passed `swiftc -frontend -parse` only. The assembled DOM, five embedded fragments and 34 distinct literal fixture scripts/snippets passed `node --check` only. The [default inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,488** source methods and the [focused inventory](browser-control-state-inventory.json) selects **805**, adding eight identifiers and removing none. Documentation targets and whitespace were checked. These checks establish syntax and source correspondence, not type correctness or passing runtime behavior.

No build, typecheck, assertion execution, inference, app/browser/computer-use launch, SSH retry, held-out inspection, push or installed-app replacement occurred. No scratch artifact was retained.

## Remaining sequence

The subsequent [retained-criterion source repair](BROWSER_RETAINED_CRITERIA_REVIEW.md) tightens retain eligibility and preserves current retain purposes in existing mixed stages. Retain-only execution remains open; the sequence below records this checkpoint's historical boundary.

1. Implement retain-only scopes and explicit supersession of earlier work without manufacturing input receipts or dropping original source purposes. Qualify semantic pending-field mapping and criterion lifetimes against complete natural-language goals.
2. Keep unresolved native tails on their original operation identities. This recovery path deliberately requires every physical journal step verified; a dispatched or partially dispatched operation whose journal remains uncertain is not qualified by this checkpoint. Lost original proof/document/process state remains a recovery limitation.
3. Continue preservation timing, dependent controls, account/login handoff and independent whole-task/result verification in the [repair TODO](../../../TODO.md).
4. After explicit execution permission, compile/run the prepared regressions and qualify actual lightweight models and real travel/concert/movie workflows. The 8 GB Mac and resource targets remain unverified. Alternate models and authorized RTX 3080 adaptation remain options after measured model failures and verified remote access.
