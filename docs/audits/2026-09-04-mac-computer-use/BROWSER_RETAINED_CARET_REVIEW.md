# Separate read-only criteria from caret preconditions

Source checkpoint: 2026-09-09. Parent: `2e6704e`. Source repair and prepared regressions only. Compilation, assertions, inference and live qualification remain paused.

## First-principles finding

A text-input snapshot contains both a value and a selection range. The range can be an input precondition, particularly when an operation inserts or replaces selected text. A retain-only review performs no text input. Moving the caret while keeping the same value therefore does not, by itself, invalidate a search criterion.

The shared form binder compared entire snapshots for both paths. That comparison appeared during private preparation, planning validation, execution validation and handback. A harmless selection change could reject the read-only review even though its original objects, desired values and native origins still held. Applying the same exception globally would weaken future input preconditions. The repair needs a bounded read-only binding path and a deliberate transition to freshly captured input state when the next reviewed stage requests an edit.

## Source repair

[EffectScopeReview](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserEffectControlReview.swift) now exposes `permitsReadOnlyRetention` from its sealed review. It requires a form with retain intents and no edit intent, an earlier continuation without unfinished edits, the same form/document/task ancestry and matching original page metadata/state. It grants no input or new value origin.

The new `bindRetainedFields` in the [native adapter](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) is available only with that review and earlier continuation. It keeps the original field IDs, exact UTF-8 values, editability/security flags, labels, choices, current control metadata and form correspondence. Only selection-range equality is omitted. Every retain intent must still map to a previously verified target with its original desired value. A fresh native requirement inspection checks the earlier input receipts or observation origins, preservation and unchanged criteria before returning.

The ordinary `bindFields` entry point always uses the original exact snapshot comparison. The underlying caret-omission switch is private to the adapter. Retained bindings return the historical captured fields rather than rewriting their original selection or value. Captured callbacks therefore stay historical; the additional native inspection is fresh. Cancellation is checked before and after each native read, and failures join outstanding DOM completion.

[Preparation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormPreparation.swift) uses this path for an eligible retain-only scope before the first binding is complete, including when the earlier field-capture callback survived Pause. The shared validation helper in [FormStage](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) uses it for a completed retain-only input. This covers preparation resume, pre/post model validation and read-only execution without changing ordinary input validation. Native preservation and original scoped readings remain required.

## Transition to a newly reviewed edit

A revised preparation can start from an unexecuted retain-only capture and subsequently request an edit. That edit needs a fresh input snapshot; the old read-only caret should not prevent establishing it.

`reviseFields` marks only an original `isRetainOnly` input with the host-side `retainedPreparation` flag. Its revision identity uses version 2; native revision shape includes the distinct mode. The native revision validates the entire old captured value/metadata/preservation/ledger baseline with selection omitted, including its inner catalogue-extension check. It then returns newly captured snapshots with the current selections. Original native target identities and values must remain the same. An absent mode retains the previous exact revision shape and selection checks; malformed mode values reject.

A version-3 preparation baseline records that its original capture was retain-only and compares those historical fields without caret equality. It still requires every original target, label, choice, value and editability/security flag, plus the reviewed source and preservation obligations. Other preparation baselines keep version 2 and their earlier exact comparison.

The resulting new edit input contains the freshly captured selection. Its text contract and later validation remain strict. A subsequent caret move can therefore invalidate that new input precondition. No input contract, receipt or stage is invented for the unexecuted retention preparation. A successful revision is still preparation, not proof that the new goal is satisfied.

## Prepared coverage and allowed checks

Nine new methods in [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift) cover:

1. Caret-only movement through preparation resume, form planning, retention execution and native query after either earlier input or no-input verification, without another edit or proof-origin replacement.
2. Movement while the form-planner fixture is suspended, followed by post-planning validation.
3. Pause after original retained-field capture but before binding, then caret movement and handback without repeating catalogue extension.
4. Revised retain-only preparation that captures the current caret and adds a source-backed City input while preserving earlier Query/Category values and actual-input history.
5. A subsequent caret move rejecting the newly captured edit precondition.
6. A mixed edit/retain scope keeping strict preparation checks.
7. Changed preservation or option metadata still rejecting despite the caret exception.
8. Pause at binding preventing another native read until handback, followed by fresh validation.
9. A changed text value preventing revision rather than being adopted along with a new caret.

The fixture helpers can now explicitly defer City until its later stage, and the planner's existing suspended-reply hook exercises the asynchronous boundary. These are authored planner decisions and unrun assertions, not natural-language model qualification.

Five changed Swift files passed syntax parsing only. The assembled DOM, five fragments and 43 distinct fixture scripts/snippets passed JavaScript syntax checks only. Inventories select **1,521 default** and **838 focused** source methods, adding nine and removing none. Documentation targets and whitespace were checked. No check establishes type correctness or passing behavior.

No build, typecheck, test assertion execution, inference, app/browser/computer-use launch, SSH retry, held-out inspection, push or installed-app replacement occurred. No scratch artifact was retained.

## Remaining work

- Recover actual criterion changes during pending preparation/model planning while preserving original captures and semantic duties. Caret-only movement is handled here; changed values and required metadata still reject.
- Continue explicit supersession and changed goals, including conflicts with preserved criteria, without discarding unaccepted work or uncertain input. A captured invariant still does not qualify as a verified task criterion.
- Qualify the interaction with later revision retries, dependent controls, scoped-reading changes and document/process recovery. Ordinary input selection checks remain deliberately unchanged by this checkpoint.
- Continue account/login handoff, independent task/result verification and the [repair TODO](../../../TODO.md). Runtime qualification, real travel/concert/movie scenarios, model comparisons and 8 GB/resource measurements await explicit execution permission.
