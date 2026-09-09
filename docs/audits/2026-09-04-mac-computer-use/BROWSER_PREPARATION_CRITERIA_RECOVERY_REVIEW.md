# Recover changed criteria before accepting a form proposal

Source checkpoint: 2026-09-09. Parent: `01cd9d7`. Source repair and authored regressions only. Compilation, test assertions, inference and live qualification remain paused.

## First-principles finding

A preparation is a retained observation and a reviewed purpose. It is not an accepted execution, a completed input or proof that the request is satisfied. If an earlier verified search criterion changes while a later retain-only input is waiting for planning, the host must preserve both facts: the old desired value and its original native history still exist, while the current page needs a fresh repair decision.

Previously, `resumeFormPreparation` and the validation before/after the form planner rejected the changed value. Execution recovery could not help because no retention proposal had been accepted into a stage. Creating a fake retention stage to reuse that recovery would falsely record unaccepted work. Clearing the preparation would discard its captured values and semantic duties. Rebinding everything from the live page would silently adopt a new baseline for unrelated fields.

## Source repair

[Preparation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormPreparation.swift) now seals a `ComputerUseBrowserFormPreparationRepair` only for a fully captured retain-only input with an earlier continuation and no unfinished edits. It restores the original metadata and scoped readings, checks owner/parent/preservation identity, and freshly inspects the earlier native requirements. A nonempty changed set must consist entirely of captured, previously repairable targets. The record holds the exact original input and changed target IDs; it grants no receipt, query, input or new criterion origin. Diagnostic descriptions expose no values.

Recovery keeps the original preparation and all reviewed source duties. [The owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) invalidates stale planning caches and requests a preparation review even when the goal revision did not change. Unsupported physical preparations return before clearing those caches or doing native work. Unchanged criteria return false and require ordinary validation. Repeating the same recovery record reports no progress; each frame accepts at most eight distinct records, and the existing revision-depth limit remains in force.

The action review still obtains fresh per-criterion change information from the actual earlier stage. It carries the unexecuted preparation's historical purposes and preservation/read obligations. A repair record disables reuse of a cached reviewed action, so a later attempt must reconsider current criteria. [Planner instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) explicitly distinguish this review from accepting the earlier unexecuted plan and from treating a newly observed value as a requested outcome.

[The driver](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift) routes eligible preparation/planning failures to this recovery in both pending-preparation and newly selected form paths. It then performs the fresh review and ordinary form planning. A retention response produced while a value changed is discarded by post-planning validation; it does not become a history entry. The existing execution recovery remains responsible for proposals already accepted into stages.

## Native revision boundary

A revised preparation retains its original input without forcing its old desired values to match the changed page. The exception is sealed into a version-4 preparation baseline and version-3 native revision identity; normal revision identities remain unchanged.

The [native adapter](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) sends two separate requirement sets: the original unexecuted capture and the earlier verified criteria. Native revision checks both again before extending the catalogue. A value exception requires the same native field ID and old expected value in both sets. Earlier dispatched-input IDs or observation-proof origins, the exact prepared input ledger, pending-change absence, original objects, labels, choices and active preservation must still hold. Required fields outside the sealed changed set keep their exact captured values. This does not make captured invariants eligible as verified criteria.

Only a retain-only original permits the existing caret exception. Changed criteria receive fresh snapshots, including selections, in the revised input. Form-input validation still requires every currently changed criterion to have a fresh edit intent; the ordinary proposal must cover every required repair with user-source-backed content. The new input contract and later validation use its exact new preconditions. The older capture is retained as history, not overwritten.

Native revision IDs and callback captures pin the newly captured snapshots. If Pause interrupts the callback, resuming cannot take another value baseline. A later value change invalidates those snapshots. This also prevents a recovery record from substituting for a fresh native origin check after the action review.

## Prepared coverage and allowed checks

Nine new methods in [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift) are authored and unrun:

1. Earlier actual-input and observation-only histories: recover unexecuted retention, keep original desired values and sources, perform only the needed repair, and then query without a fabricated retention receipt.
2. Driver recovery before its form planner runs.
3. Driver recovery when a value changes while the form planner waits, discarding that retention proposal.
4. Pause at page observation or requirement inspection: no published recovery or extra native activity until handback.
5. Rejection of changed writable/read-only preservation, option metadata and required native objects.
6. Loss of native origins after the repair review, checked again during revision, for both origin types.
7. A captured revision interrupted by Pause followed by another value change, without a replacement capture.
8. Unsupported physical preparation leaves its planning state usable; unchanged retention requires normal validation.
9. Accepted answer purposes remain in the historical preparation context while earlier executed history stays unchanged and private values stay out of model context.

Allowed checks: six changed Swift files parsed with `swiftc -frontend -parse`; the assembled DOM, five fragments and 45 distinct fixture scripts checked with `node --check`. Source inventories select 1530 default / 847 focused methods, exactly nine additions each and no removals. These are syntax and source-inventory checks, not compilation or test results.

## Remaining repair order

- Handle value changes before the original private capture/binding has produced a complete input. Preserve its callback captures and duties without treating a partially constructed input as authority. This change deliberately refuses that earlier boundary.
- Review subsequent changed criteria during an already revised physical preparation, clarification and cancellation. The fresh revision remains held and cannot automatically adopt another value.
- Continue explicit supersession and changed goals, including conflicts with preserved criteria. Historical source overlap is not semantic equivalence or permission to remove an obligation.
- Reconcile changed scoped readings, dependent controls and document/process loss. Required metadata or preservation failures still stop this path.
- Continue account/login handoff and independent research-result verification from the [repair TODO](../../../TODO.md).
- Qualify actual natural-language travel, concert and movie workflows, model alternatives and the 8 GB Mac target only after explicit execution permission. No model run, desktop SSH retry, browser/app execution, push or installed-app replacement occurred at this checkpoint.
