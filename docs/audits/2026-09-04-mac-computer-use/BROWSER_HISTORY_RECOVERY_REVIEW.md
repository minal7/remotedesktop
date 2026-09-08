# Recover when an unsent return to an earlier page is no longer valid

Source checkpoint, 2026-09-08. Previous checkpoint: `bafc061`. Execution remains deferred.

## First-principles defect

A pending navigation is an intention, not necessarily an action. If the user changes pages during a login handoff, an intended Forward entry can disappear from browser history. The preceding history stage correctly refused to turn that Forward operation into a fresh GET. However, it retained the now-impossible operation indefinitely, leaving no route back to planning the remaining task.

Deleting the stage would create a different defect: an old caller could still execute it while the new planner starts a replacement. A missing receipt is insufficient evidence that nothing happened. Recovery needs both an exact durable no-attempt record and a live native no-attempt check, followed by revocation before a replacement gets an identity.

## Source changes

- [Native navigation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) now has synchronous retirement for a task-bound observed operation. It checks live ownership, context, idle navigation/DOM state and absence of any native attempt or receipt. It records the exact operation and payload as revoked. Repeated retirement of that same binding is idempotent; a different binding cannot borrow its proof. Completed or uncertain native operations cannot be retired this way.
- Both observed navigation and generic native loading reject revoked IDs. Loading checks revocation again around the durable dispatch callback, so callback reentrancy cannot revive a just-cancelled operation. Revocation remains separate from attempt evidence: it does not falsely record a navigation attempt or create a navigation receipt.
- [The journal adapter](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserNavigationTask.swift) holds the same execution lease used by navigation while validating the exact task, prompt, contract and step IDs. Only an absent initial journal or an exact single `planned` status is eligible. Attempted, uncertain and verified journals are preserved and cannot grant retirement, even when the native browser has no receipt.
- Native revocation precedes the existing durable retirement write. The journal keeps its original identity and statuses and adds a digest bound to that exact operation and payload. No file is deleted or reset to `planned`. A matching retirement record can be rewritten to resolve a prior unconfirmed flush. A competing lease, foreign binding or incompatible retirement marker blocks recovery.
- Ordinary open, replan and ambiguous-binding resolution now reject retired journal records. Native revocation also blocks reuse if a same-session caller loses the disk record. Replanning checks revocation around its asynchronous preparation and validation, before publishing another binding. The store's existing permanent-retirement and compare-and-write checks remain unchanged.
- [The retained history stage](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchHistoryNavigation.swift) resolves any known alternatives from a failed page-binding replacement before attempting retirement. Once retirement begins, the old stage cannot run while its outcome is unresolved. Failed storage keeps this state for a later leased retry. A successful retirement receipt is retained before the final cancellation/control check, so Pause after persistence cannot erase it.
- [The research owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) releases a pending history stage only after receiving its retirement receipt. It records cancelled intentions separately from confirmed navigation visits and clears speculative page/action caches. The full original request, accepted answers, reference clock, actual completed visits and archive remain intact. A retired intention is neither a completed visit nor an answer.
- [The driver](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift) uses this recovery after a changed/unavailable/out-of-policy history target, and when a prior retirement still needs reconciliation. It then observes the current page and asks for a new step. It does not infer a replacement URL or silently change Forward into GET. Attempt uncertainty, journal errors, lost ownership, authentication and ordinary cancellation do not become permission to start over. Fresh stages keep the existing monotonically increasing sequence and 32-stage bound; retirement cannot reset that namespace.

This is recovery for pending history/revisit stages. Result-link and form-query stages retain their separate recovery rules. Native revocation is scoped to the live task context; it does not replace durable parent-task recovery or prove behavior across a replaced browser process. Explicit login handback remains required.

## Prepared verification

Seven new methods in [history coverage](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchHistoryTests.swift) specify:

1. A pending Forward operation evicted by a different branch during Pause; the actual driver retires it without loading its URL, preserves the original goal, then accepts a separately selected GET revisit with a new operation ID.
2. Old native and newly constructed journal callers failing to execute, replan or resolve a retired operation. Removing the fixture's retirement file cannot undo the live native revocation or call the planner.
3. A retirement write failing after replacement: the stage remains pending, its old execution is blocked, and the driver resolves the same retirement before returning to planning.
4. Pause immediately after a successful retirement write: the original receipt survives explicit handback without another write or navigation.
5. An unconfirmed page-binding replacement followed by retirement: resolution uses the binding actually present on disk while preserving the original operation ID.
6. A competing execution lease and a foreign journal each blocking retirement; restoring the original journal permits the same pending retirement to finish.
7. A confirmed history navigation refusing retirement and replaying only its historical receipt.

The existing uncertain-attempt method now also requires retirement to return no proof, retain the pending stage and preserve the journal without a retirement marker. These assertions are prepared but unrun; they are not native, model or provider qualification.

The [default source inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,168 methods** and the updated [history inventory](browser-history-navigation-inventory.json) selects **485**. Six changed Swift files pass syntax-only parsing. Source inventories, project syntax, local documentation links and whitespace are checked. No typecheck, build, test assertions, model inference, app launch, browser/computer-use activity or held-out inspection/run occurred. This work generated no disposable runtime/build output and did not replace the installed app or model assets.

## Remaining repair order

1. Carry actual selected control state into complete result evidence. Labels and listed options do not establish the selected travel date, party size or ticket type. Reconcile dates, time zones, quantities, package/limit rules, eligibility, prices, totals and fees before reporting a requested option as supported.
2. Complete association and conflict handling for facts about one offer across several pages. Semantic deduplication, ranking and full requested-source coverage remain unqualified. Larger findings need complete delivery without dropping source qualifications.
3. Repair the remaining form/link/query recovery gaps and durable research-parent/archive recovery. This retirement mechanism does not resolve attempted or uncertain effects without independent receipts, and closing the browser still loses its nonpersistent context.
4. After execution authorization, typecheck/build and run bounded deterministic checks, including history callback ordering and cached restoration, then qualify actual-model decisions and context fit. Do not infer runtime correctness from parsing or fixture counts.
5. Keep the travel/concert/movie real-site scenarios deferred until readiness and explicit permission. Alternate models and authorized RTX 3080 adaptation remain available when measured model errors justify them; SSH/hardware access remains unverified. Performance optimization and physical 8 GB/thermal qualification remain later work.
