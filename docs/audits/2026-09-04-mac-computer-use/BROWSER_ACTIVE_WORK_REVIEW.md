# Retain an allowance for active browser work

Source checkpoint: 2026-09-09. Parent: `def79c8`. Source repair and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

Navigation count and individual proposal deadlines do not bound a research task that repeatedly reviews or recovers a form without navigating. Each proposal can finish within its own deadline, and each recovery can return without incrementing the visit count, while the orchestration continues indefinitely.

A time policy must distinguish work from waiting for the user. Counting a long login or clarification pause as autonomous effort would consume the allowance while the app is not researching. Recreating the allowance on Resume or an accepted answer would instead let the same failing task repeat indefinitely. Neither elapsed time nor a counter establishes meaningful progress; exhaustion must leave the request pending rather than declare success or discard requirements.

The [navigation-limit repair](BROWSER_NAVIGATION_LIMIT_REVIEW.md) keeps the final page readable. This change adds a separate admission policy for cumulative driver-active elapsed time.

## Clock and lifetime

`ComputerUseBrowserWorkBudget`, in the [driver source](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift), uses a monotonic clock and retains remaining duration. Production starts with a ten-minute allowance; configuration must be positive and at most one hour. These are current engineering defaults requiring qualification, not measured task-success, latency or thermal targets.

| Boundary | Accounting |
| --- | --- |
| Initial text-only interpretation | Starts the first active segment before the proposal |
| Failed same-request admission and retry | Retains consumed work alongside the original input and date context |
| Admitted browser owner | Receives the same budget object as the driver run |
| Active search, planning, native stage or recovery | Charges elapsed time inside the driver call |
| Returned clarification, intervention, Pause or failure | Closes the segment in `defer` |
| User work between calls | Does not consume the allowance |
| Explicit Resume or accepted answer | Opens a segment using the remaining allowance; does not refill it |
| Exhausted continuation | Returns a nonterminal intervention without starting another automated stage |

Checkpoints charge only the interval since the previous checkpoint, preventing double charging. Finishing is idempotent. An overlapping begin cannot replace an active segment. A regressed injected clock exhausts capacity instead of refunding time. Wall-clock date/time-zone changes cannot alter this monotonic accounting or the request's existing date contexts.

Busy competing admission still restores the preceding admission record, including its budget object. This is in-memory state for the current driver and admitted owner. It does not add durable recovery of budget consumption across process restarts or displaced requests.

## Stage and proposal admission

The driver checks the allowance at every loop iteration, navigation admission, and transition from a completed proposal/preparation to another automated stage. This includes form review, revised preparation, form planning/input, dropdown actions, result reading, answer preparation and report preparation. Pending link replacement receives a fresh capacity check before its subsequent navigation call.

Already-admitted native stages retain their existing execution, verification and cleanup boundaries. A stage may finish after the allowance expires; its confirmed receipt remains authoritative. Native recovery associated with a failed admitted stage can retain its history, after which the next loop admission checks the remaining allowance. The budget does not detach native effects, convert uncertainty into a failed attempt, replay input or discard a retained preparation.

The same budget passes through [host preparation](../../../host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift) and [navigation ownership](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserNavigationTask.swift). The [owner's proposal boundary](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) limits a model wait to the smaller of its stage limit, any existing decision deadline and the remaining allowance. If the whole allowance caused a timeout, the owner reports that exhaustion; a shorter ordinary stage timeout keeps its existing typed error.

The [planning worker](PLANNING_DEADLINE_REVIEW.md) still retains actual model capacity until an overdue/cancelled call exits. A late proposal cannot refill the budget or authorize an effect. Driver-active time stops at the caller's return, so an uncooperative model's later lifetime is handled by that worker, not charged as CPU/GPU time by this clock.

Manual native handback and direct owner inspection do not start driver accounting segments. Attached proposal calls still cannot bypass an already exhausted budget, including after the late model returns. This is a browser-driver work policy, not a universal deadline for every internal owner API or other capability.

Ownership checks remain separate from time admission. A completed answer or receipt is not rejected merely because the clock crossed the limit during its already-admitted native verification. Questions and login handoff can still return control to the user. None of these outcomes replenishes time or weakens complete-goal/source predicates.

## Authored verification, unrun

Eleven new methods specify:

- Six budget methods: cumulative active segments versus manual time; repeated checkpoints; overlapping begin; invalid allowances; a regressed clock; fractional remaining time and invalid stage limits.
- Four driver methods: an accepted answer retaining previously consumed time across a long simulated manual interval; expiry after a form proposal preventing input and surviving handback; expiry during admitted input retaining its receipt while blocking the next stage; failed initial admission retaining consumed time on retry.
- One owner method: a short active allowance bounding a deliberately stalled proposal despite a longer stage limit, retained worker capacity until actual return, discarded late output and rejection of planning after exhaustion.

These use simulated clocks and controlled fixtures; they are authored assertions, not results. Six changed Swift files pass parse-only checks. Active default/focused inventories select 1809 / 1126 methods, with eleven additions and no removals. Existing files already belong to the project; the additional test class is selected explicitly in both inventories.

## Remaining repairs and qualification

1. Add capability-specific evidence of progress and repeated-state detection. A ten-minute ceiling cannot tell useful recovery from repeated ineffective proposals; it should not be the first indication of a stalled task.
2. Define an explicit user flow for extending or otherwise resolving an exhausted allowance without silently replacing the request, resetting history or replaying uncertain effects. Resume currently preserves the exhausted state and explains that it does not extend the limit.
3. Qualify actual driver/model/native timing, cancellation, app suspension, power transitions and cleanup. This is admission control, not a hard wall-clock guarantee: a blocked native call or stalled main actor cannot be forcibly preempted here, and an admitted native stage can overrun its admission time.
4. Define durable accounting and recovery for application/process restarts and all capability routes. Initial runtime activation and direct internal owner work are not universally charged by this driver policy.
5. Continue the [repair checklist](../../../TODO.md), including complete provider semantics, source-history qualification, general corrections and model competence. No whole-goal correctness, 8 GB memory or fan-load qualification follows from this patch.
6. Keep real travel/concert/movie/login runs and model/RTX 3080 adaptation at their later authorized stage. No model, SSH, app or browser execution occurred here.
