# Recover earlier criteria without replacing a physical preparation capture

Source checkpoint: 2026-09-09. Parent: `b0031b6`. Source repair and authored regressions only. Compilation, assertions, inference and live qualification remain paused.

## First-principles finding

A form preparation can contain several kinds of evidence at once. Query and Category may already have verified task values, while City has only been captured for a proposed future edit. Capturing City does not make its value a verified task criterion. Conversely, an earlier Query value changing does not erase City's original input preconditions.

The previous recovery traversed a physical revision only before that revision started any private capture. This protected its callbacks and newly observed fields, but also left a recoverable case held: an earlier verified criterion could reset after the current frame captured City. Discarding the frame would lose City; accepting every changed field would silently replace its baseline. Recovery needs an exception tied to the earlier criterion's native origin, applied independently to each captured field.

The captured Query value can itself differ from its earlier desired value. A physical scope may already have requested Query repair when it captured `reset`, and the page may later change it to `another`. All three facts matter: the original desired value, the historical capture, and the current observation. None may be substituted for another.

## Source repair

[The sealed scope review](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserEffectControlReview.swift) now exposes eligibility to reobserve earlier criteria for either an edit or retain scope. It requires the same form and document, a continuing goal, matching reviewed metadata, and no pending earlier edits. The narrower read-only capability still controls its existing caret exception.

[Preparation recovery](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormPreparation.swift) can finish its own original field, binding and preservation captures without creating a planner input. A physical revision with no started capture still prefers inherited recovery when its ancestor is eligible. Once its own capture starts, it recovers that capture, including newly discovered fields. It never skips a started callback, clears an attempt or recaptures an unknown result under changed arguments.

[The field adapter](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) checks earlier native criterion origins before binding. The exception set contains only current value changes or historical capture differences backed by previously verified, unpreserved targets. Binding keeps the original field snapshots; it does not adopt current private values. For a physical preparation, values and carets outside that set remain exact. Labels, choices, object identity, document identity, preservation and scoped readings keep their existing checks. A second native origin inspection and cancellation checks precede publication of the recovery record.

The record requires a nonempty change set, includes every historical captured criterion difference, and remains bounded by the existing per-frame limit. It carries the actual original capture and previous continuation. It creates no form stage, edit receipt, observation proof or query authority. [The task owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) clears cached planning results and requires a fresh action review before the next form proposal can be accepted.

## Native revision and fresh input

Physical repair uses the distinct `repairable-planned-form-v1` native requirements kind. Native validation accepts it only for preparation with separate earlier criterion origins and physical selection checking enabled. It checks the exact native input ledger and operation IDs, absence of pending native changes, preservation, and membership of every exception in both the captured form and the original verified criteria.

For masked fields only, the historical capture can differ from the earlier desired value, and its obsolete caret can differ from the current caret. Unmasked new fields keep their exact captured values and carets. The same checks run at the actual native revision boundary, so changes after the fresh action review cannot silently replace the baseline.

The new format cannot pass ordinary query or state-proof validation. Revision captures keep their existing one-use cache and strict returned snapshots. A successfully revised input returns to ordinary physical preconditions. The new scope and form proposal must cover required repairs; earlier actual input IDs, observed origins and sources remain in the unchanged continuation until real new work completes.

Physical repair has distinct requirement/repair digests, version-5 native revision IDs and version-7 preparation baselines. Other paths retain their prior digest versions. Baselines continue to distinguish the actual capture's review context from later reviewed purposes and preserve intervening accepted duties and answers.

## Prepared coverage and allowed checks

Eight methods were added to [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift), and one earlier boundary case was renamed and extended. All are authored and unrun:

1. A started answered revision recovers its own expanded capture, including City, and requires a fresh scope before repairing Query and entering City. The earlier smaller capture cannot replace it.
2. Physical captures interrupted after field extension, binding or preservation recover earlier criteria with actual-input or observation-only history; recovery performs no input or disk publication.
3. A completed physical preparation rejects its stale City-only proposal after recovery and retains City's exact original snapshot through the new review.
4. Changed new-field values, replaced new objects and changed preservation prevent recovery from interrupted captures.
5. A new field's changed caret prevents recovery, both with and without an earlier criterion value change.
6. Pause during binding or the final origin inspection prevents publication and further native work until explicit handback.
7. Lost native input or observation origins after review prevent the new physical revision.
8. A captured repair value remains distinct from both its earlier desired value and a later changed value; fresh work repairs the earlier criterion without rewriting history.
9. A new field changing after recovery and fresh action review still prevents native revision.

Five changed Swift files passed `swiftc -frontend -parse`. The assembled DOM, five embedded fragments and 51 distinct fixture scripts passed `node --check`. Source inventories select 1554 default / 871 focused methods: eight additions and exactly one reviewed rename in each inventory. These checks establish syntax and source selection only; they do not establish compilation, assertion results or browsing correctness.

## Remaining repair order

Follow-up: the [new-edit refresh checkpoint](BROWSER_NEW_EDIT_REFRESH_REVIEW.md) adds a separate fresh-review path for changed values and carets of newly captured edit fields. It retains the old capture until the new scope explicitly requests those edits and native revision captures strict replacement preconditions. Earlier invariants, preserved fields and scoped readings remain excluded. The earlier new-field value/caret boundary cases were revised; execution remains pending.

- Reconcile changes to newly captured, unverified fields through explicit supersession instead of adopting their current values or carets. Current recovery deliberately holds them.
- Continue accepted preservation/read-duty and immutable-observation handling across repeated physical revisions and answers, including conflicting answers and justified removal of obsolete duties.
- Reconcile dependent controls, required metadata changes, document/process loss and uncertain input while retaining original evidence.
- Continue account/login handoff and independent research-result verification in the [repair TODO](../../../TODO.md).
- Qualify real natural-language travel, concert and movie tasks only after explicit execution permission. Compare alternate models against measured failures before desktop adaptation, then qualify the 8 GB Mac resource target. No app/browser execution, test assertions, model runs, SSH retry, push or installed-app replacement occurred here.
