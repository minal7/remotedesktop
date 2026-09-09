# Recover a revision rejected before new fields were captured

Source checkpoint: 2026-09-09. Parent: `5c1a70f`. Source repair and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

Starting a native call is evidence of dispatch, not evidence that it captured new fields. A revision can reject the original catalogue's preconditions before its extension routine reads new field values. The host previously held every such failure as a started capture and could not reach fresh review through the earlier frame.

The opposite shortcut would also be wrong: a failed callback does not establish absence. An extension may have read part of its new catalogue, completed before cancellation, or returned an unreadable result. Clearing its capture or retrying it with new arguments would lose the distinction between historical and newly observed state.

The necessary fact is narrow: this exact native revision ID, in this exact document and input ledger, was rejected before the revised catalogue capture began. This is neither input retirement nor a form-state proof. It authorizes no field edit and says nothing about task completion.

## Native result and one-use identity

[The native adapter](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) now emits `revision-not-captured` with `uncapturedRevisionID` only when a validly identified new revision fails the earlier-catalogue requirement or refreshed-selection check before entering `extendFields`. Before returning it, the adapter seals that ID in the existing bounded revision map. Repeating the ID cannot capture again, even if the original field values return. A new reviewed scope and repair record produce a distinct attempt.

An existing revision ID cannot gain an absence result. Its completed or uncertain capture remains governed by the original cache. Failures after entering extension keep the existing conservative handling. Early argument/scope rejection, exceptions, missing callbacks, lost native history and exhausted capacity do not gain an absence witness.

[Reply decoding](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) requires the revision command, the exact status, a 64-character hexadecimal revision ID, a 32-character hexadecimal ledger and no field, page, proof, binding, popup or option-selection payload. Normal document validation still applies. The new field on any other reply or command is rejected.

[The host capture](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOMReadCapture.swift) correlates the result with the revision ID stored when that exact command began. Its document, argument digest, completion and started flag remain retained. The target checks native document and ledger identity before accepting this historical fact. Reusing the capture with different arguments remains forbidden, and a second completion cannot overwrite an earlier result.

## Recovery without losing the current task

[Form preparation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormPreparation.swift) can inherit its earlier capture when its revision has the explicit witness and has no fields, binding, preservation completion or prepared input of its own. The frame, answered goal, frozen origin, semantic purposes, required edits and preservation/read duties stay retained. Unknown and completed captures remain on their own recovery path.

Recovery uses the existing ancestor reconciliation: original-page and owner checks, earlier native criteria or empty-history inspection, preservation validation, and fresh edit requirements. It does not publish a receipt, proof or input journal. A rejected frame cannot resume preparation directly. The owner must review a new action and form proposal before any fresh capture or input can proceed. Pause and handback checks still surround publication and native work.

## Prepared coverage and allowed checks

Eight methods were added to [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift), and the earlier post-review new-field-change case was extended. All are authored and unrun:

1. Reject malformed absence replies, mixed payloads, missing IDs and use on unrelated commands.
2. Bind the witness to its original revision, document and ledger; retain arguments and the started callback.
3. Keep pending, ordinary failed and completed captures from becoming absent through a later completion.
4. Seal a rejected native ID after the original field value returns; reuse needs a distinct reviewed attempt.
5. Refuse to reclassify a completed native revision when earlier fields subsequently change.
6. Retain an answer through a rejected initial revision, then create only the first actual stage.
7. Keep changed preservation and required-object replacement from being discarded through recovery.
8. Exercise the driver's pending-preparation loop after a proven rejection, with one eventual form proposal and no input replay.

The extended mixed case changes a new City field after an earlier Query repair has been reviewed. It covers ordinary rejection and cancellation after the native callback, requires handback before recovery, rejects a fresh scope that defers the changed City field, and preserves actual earlier input history through the eventual repair.

Five changed Swift files passed `swiftc -frontend -parse`. The assembled DOM, five embedded fragments and 58 distinct fixture scripts passed `node --check`. Source inventories select 1580 default / 897 focused methods: eight additions each, with no removed or renamed identifiers. These are syntax and source-inventory checks only; they do not establish compilation or passing assertions.

## Remaining repair order

- Failures after revised catalogue capture starts, unclassified early failures, lost callbacks and lost native history remain held. Any broader recovery needs authoritative reconciliation that preserves every observation already made.
- Continue explicit goal supersession, conflicting answers and justified changes to earlier invariant, preservation and read obligations. A rejected capture does not make the current reviewed task disposable.
- Complete login document transitions, process/account recovery, required-object replacement and dependent-control reconciliation without rewriting task or effect history.
- Continue result verification and the full [repair checklist](../../../TODO.md). Real travel/concert/movie tasks, alternate-model comparisons, desktop model adaptation and the 8 GB resource target remain unqualified. No assertions, app/browser execution, inference, SSH retry, push or installed-app replacement occurred here.
