# Retaining an observed prefix before unsent input

Source checkpoint: 2026-09-09. Parent: `37290cd`. Source implementation and prepared regressions; execution qualification remains paused.

## First-principles failure

Completing a criterion does not require typing when the desired value is already present and independently verified. Interruption must retain that completed work even if the next physical input never began. An input-centric prefix count cannot express the distinction by itself.

The [ordered checkpoint](BROWSER_ORDERED_VALUE_CHECKPOINT_REVIEW.md) could retain a prefix containing at least one verified native input. The earlier [mixed-stage repair](BROWSER_MIXED_FORM_PREFIX_REVIEW.md) could verify leading criteria without input. Combining them exposed a gap: when the first physical input failed before native dispatch, `retainVerifiedPrefix` returned no prefix because its physical input count was zero. Whole-stage retirement could then discard the already verified observations. Conversely, a matching field after an actual native attempt must not be treated as evidence that the input was unsent.

## Source repair

[ResearchFormStage](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) can now construct a partial continuation from its retained leading native state proof when the exact journal has no verified physical input. This constructor preserves the original observed targets, source purposes, desired values, earlier continuation and preservation. Every physical input remains an explicit pending entry. The proof is still required; an attempted mixed journal reconstructed without its native observation origin cannot produce this prefix or use whole-stage retirement to discard it.

Construction is only a candidate. Before publication, the native adapter checks the original proof origins and exact actual-input ledger, current required objects and preservation, proves every remaining operation unsent, and revokes all those original IDs. The stage then writes and reconfirms the retirement under its original execution lease. Its new retirement digest binds the retained native observation proof, stage, goal and input contract. A late Pause or failed durability confirmation can retry only that retirement and publish the same partial history once.

The [journal](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseTaskExecution.swift) now permits `retainedPrefixCount: 0` alongside a retirement digest. This counts retained physical inputs, not observations. It distinguishes observation-prefix retirement from whole-stage retirement, whose count is nil. The [store](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseTextStepStore.swift) requires zero verified input flags in that case and preserves all planned/attempted/uncertain flags. Ordinary saves, unattempted rebinding and whole-stage retirement cannot create, remove or reinterpret the marker. Retirement still requires the execution lease and an exact compare against the loaded journal. The marker alone is never native proof or execution authority; ordinary execution rejects retired journals.

Partial receipts explicitly report zero inputs, the nonzero observed count, and the original total criterion count. The existing owner/driver carries that partial stage forward, withholds query controls, and requires complete fresh mappings for the unsent remainder. Later input keeps the observed criteria as obligations. If an observed editable criterion changed, it remains an explicit repair alongside the pending work; it cannot silently adopt the changed value.

## Definitive refusal preserves input reconciliation

The [native retirement command](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) now checks for a known suffix operation immediately after validating the document, ledger and operation-ID shape. A present operation returns `unproven` before current criterion checks, with no revocation. Previously state-proof validation could reject the extended ledger first and leave the stage stuck in retirement-pending state even though retirement had definitively not happened.

On the definitive refusal, the stage clears retirement-pending, records that native input was observed and leaves its original journal and reconciliation path intact. It cannot fall back to whole-stage retirement. The existing input receipt/outcome checks decide whether the original operation can complete; no input is replayed and no fresh observation replaces uncertain input history. Unknown ownership, lost ledger, absent proof, or changed preservation still withhold publication.

## Prepared regressions and limited checks

Ten methods were added to [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift):

1. Retain an observed Query with zero inputs after a failed first attempt write; remap Category/City, then retain an explicit query path.
2. Continue that case through the actual driver using authored planner decisions.
3. Retain observation before even a disk input attempt, after explicit handback from Pause.
4. Refuse retirement after the first actual native input, then reconcile the original stage without duplicate input or observation.
5. Recover Pause at native retirement/publication and a failed retirement durability confirmation without duplicate history.
6. Reject lost original objects, lost ledger and changed preservation.
7. Carry a changed observed criterion as repair alongside every unsent entry.
8. Refuse both retirement paths for an attempted mixed journal without its observation proof.
9. Reject ordinary invention/removal of a zero-input retirement marker, unleased retirement and changes to the saved retirement identity.
10. Retain earlier stages' actual input IDs when the current stage has zero completed inputs, then continue through the remaining input and explicit query.

Five changed Swift files passed `swiftc -frontend -parse` only. The assembled DOM, five fragments and 33 distinct literal fixture scripts/snippets passed `node --check` only. The [default inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,480** source methods; the [focused inventory](browser-control-state-inventory.json) selects **797**, adding ten identifiers and removing none. Documentation targets and whitespace were checked. These results establish syntax and source correspondence, not type correctness, passing assertions or model behavior.

No build, typecheck, assertion execution, inference, app/browser/computer-use launch, SSH retry, held-out inspection, push or installed-app replacement occurred. No scratch artifact was retained.

## Remaining sequence

The subsequent [full-input history checkpoint](BROWSER_FULL_INPUT_RECOVERY_REVIEW.md) implements the source path for an all-verified physical journal whose current criteria need repair. The sequence below remains this checkpoint's historical boundary; execution qualification is still pending.

1. Recover a stage whose full physical input sequence has native receipts but invalidated an earlier observed criterion before final completion. Retain the historical inputs and original observed goal as explicit repair work; the current proper-prefix interface cannot express that full-input recovery case.
2. Implement retain-only scopes and explicit supersession of earlier work without manufacturing input receipts or silently dropping original requirements. Qualify semantic pending mappings and criterion lifetimes.
3. Continue document/process recovery, preservation timing, dependent controls, account/login handoff and independent whole-task/result verification in the [repair TODO](../../../TODO.md).
4. Compile and execute prepared coverage only after explicit permission. Actual lightweight-model and live travel/concert/movie qualification, resource measurements and the 8 GB Mac target remain unverified. Alternative model/RTX 3080 adaptation remains authorized after measured model failures and verified remote access.
