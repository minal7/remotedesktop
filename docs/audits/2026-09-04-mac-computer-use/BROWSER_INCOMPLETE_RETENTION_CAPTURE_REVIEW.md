# Recover retention before a valid planning input exists

Source checkpoint: 2026-09-09. Parent: `e508982`. Source repair and authored regressions only. Compilation, test assertions, inference and live qualification remain paused.

## First-principles finding

A private field capture and a valid form-planning input are different facts. A native callback may capture fields before Pause cancels its waiter. A field may also change after the action review but before that first private capture. In the latter case, a retain-only input cannot honestly be constructed: the captured value does not match the earlier requested criterion.

The preceding recovery required `preparedInput`. That left an interrupted field read, binding or preservation read unable to request repair. Completing an artificial retain-only input with substituted desired values would invent an observation. Repeating field discovery would lose the original capture. Treating the captured changed value as the requested outcome would lose the user's intent.

## Source repair

[Preparation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormPreparation.swift) now has a separate `ComputerUseBrowserFormPreparationCapture`. It records the interpretation, historical field evidence, form, earlier continuation, scope review, preservation and any preceding baseline. It supplies no editable aliases, proposal or receipt. A conversion from an already valid input records `wasPreparedInput = true`; only the preparation file can construct the incomplete retain-only variant.

The incomplete constructor requires a sealed retain-only review with the same goal ancestry, document and form, all earlier required targets, unique field/control identities, the reviewed discovery/preservation set and verified origins for every retain intent. It retains original baseline obligations and native preservation identity. It deliberately does not claim that captured criterion values meet the goal.

The original native capture sequence now lives in a shared `captureFields` helper. Ordinary preparation still constructs and fully validates a real `ComputerUseBrowserResearchFormInput` afterward. Recovery may finish the original captures without constructing that input. Existing callback captures remain in place for field discovery, binding and preservation, including replies delivered after cancellation. It does not clear a failed capture or obtain a new field baseline to hide its failure.

[The owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) determines eligibility from the sealed review and earlier continuation, rather than from the presence of a complete input. Physical/mixed preparations remain ineligible and return before clearing their planning caches. The driver already routes eligible preparation failures through this owner method.

## Binding historical fields for a repair review

The [adapter](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) adds `bindRetainedFieldsForRepair`. Like ordinary retained binding, it requires the sealed read-only review, original document/form/control correspondence, labels, choices, editability/security flags and earlier verified targets. Only previously verified, unpreserved criterion targets can differ in value. Other captured values remain exact. Selection omission remains confined to the retain-only path.

The binder returns the original captured fields, not replacement values. It freshly checks the native earlier input receipts or observation origins and current preservation. Recovery also performs a fresh binding after completing any historical callback captures, so cached binding data cannot stand in for current object/invariant checks. Ownership and cancellation checks surround the reads; errors join outstanding DOM completion.

The sealed repair set is the union of current changed criteria and captured values that differ from their earlier desired values. It must be nonempty and entirely within earlier repairable targets. The second component matters when the first capture saw a changed value and the user restored the requested value before recovery. The historical capture is still stale even though current criteria no longer need input. A fresh action review can then choose retention, followed by ordinary current validation, without dispatching unnecessary input.

Recovery still publishes no form stage, input receipt, observation proof or completed task. The earlier executed history remains unchanged. The normal form-input constructor alone creates a later valid input; the execution owner still requires that exact prepared input before accepting a proposal.

## Native revision authority

Incomplete captures use `captured-retained-form-v1` requirements, a distinct requirement digest, version-4 revision identity and version-5 baseline. Conversions from previously valid inputs keep their existing requirement kinds and identities.

Native revision accepts the captured-retention kind only in preparation mode, with read-only selection handling and a separate verified-origin requirement set. It checks the complete captured shape and exact input ledger, absence of pending changes, current native objects, metadata, choices, preservation and earlier input/proof origins. A repair exception still needs the same submitted field ID in both requirement sets. For this kind alone, the captured value need not equal the earlier desired value: these two values describe different historical facts. Every target outside the sealed repair set keeps its captured value.

This kind is rejected as ordinary query requirements and as a form-state verification baseline without the separate repair-origin path. It is not a new proof format. Native revision results and retained callbacks still pin the newly captured snapshots. Later actual input uses the normal strict snapshot preconditions and fresh source-backed repair intents.

## Prepared coverage and allowed checks

Eight new methods in [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift) are authored and unrun:

1. Pause after retained-field capture, binding or preservation, for both earlier actual-input and observation-only histories; recover and repair without manufacturing an original planning input or retention stage.
2. Pause before the first field capture, followed by a changed value, for both history types.
3. Driver recovery from interruptions before and after that first capture, repairing only the changed criterion and then querying.
4. A first capture that saw a changed value followed by user restoration; a fresh retain-only review performs no additional input or state proof.
5. Changed writable/read-only preservation and replaced original objects still reject.
6. Pause during recovery's own binding, with no further native activity until handback.
7. Native origin loss after reviewing a repair from an incomplete capture still prevents revision.
8. An unchanged interrupted capture still requires ordinary input preparation and execution validation.

Allowed checks: four changed Swift files parsed with `swiftc -frontend -parse`; the assembled DOM, five fragments and 46 distinct fixture scripts checked with `node --check`. Source inventories select 1538 default / 855 focused methods, exactly eight additions each and no removals. These checks do not establish compilation or runtime correctness.

## Remaining repair order

The subsequent [answered-preparation recovery](BROWSER_ANSWERED_PREPARATION_RECOVERY_REVIEW.md) keeps earlier capture recovery reachable through newly installed revisions whose own native capture has not started. The list below records this checkpoint’s earlier boundary; started physical captures and broader clarification/supersession coverage remain open.

- Review recovery during later physical/mixed preparations and additional criterion changes during revised capture. Those paths retain their original preconditions; this repair does not authorize discarding them or replaying uncertain input.
- Review ordering when an accepted answer installs a physical revision over an earlier unfinished retain-only frame. Recovery must still reach that earlier capture without relaxing the new input scope. Extend clarification coverage across nested frames while retaining every accepted preservation/read duty and source purpose.
- Continue explicit goal supersession and conflicts with preserved criteria. Source overlap is not semantic equivalence; captured invariants do not become verified criteria.
- Reconcile changed required metadata, scoped readings, dependent controls and document/process loss without replacing original evidence.
- Continue account/login handoff and independent research-result verification in the [repair TODO](../../../TODO.md).
- Actual natural-language travel, concert and movie qualification, alternate-model comparisons, desktop adaptation and the 8 GB Mac target remain deferred until explicit execution permission. No app/browser execution, model run, SSH retry, push or installed-app replacement occurred here.
