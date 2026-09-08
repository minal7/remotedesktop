# Repairing reset criteria on a retained native form

Source checkpoint after `fd5b24d`. Runtime qualification remains paused and the [working repair list](../../../TODO.md) remains open.

## First-principles failure

Historical success, current state and intended state are different facts. A category selected earlier may later be reset by a website. Its original input receipt is still valid history, but its old expected value is no longer true. Previously the native extension required every old value to match before the next planner could see the form. That stopped a task even when a new, justified edit could repair it.

Ignoring the mismatch would be equally wrong: the new contract could accept the reset value as an unchanged invariant and submit incorrect criteria. Copying old private values back blindly would also miss an accepted answer that changed the user's intended city. The remaining work must explicitly require a new goal-backed operation for each changed criterion. Historical input receipts remain part of the chain; they do not authorize replay or prove the repaired goal complete.

## Source implementation

1. **Inspect before offering a query.** [The research owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) asks the retained stage to inspect its required native fields after observing the current page and before action planning. The [stage](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) retains its operation slot through cancellation and joins the outstanding DOM completion before releasing it.
2. **Keep native receipt and object checks.** [The isolated DOM dispatcher](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) checks the exact current page/document, required field bindings, every original dispatched operation and explicit preservation. Only values on earlier edited, currently unpreserved targets may differ during inspection or extension. Missing/replaced objects, changed shapes, lost receipts and changed preservation still fail. The new `inspectFormRequirements` command returns at most sixteen changed native IDs; current field values stay inside this read-only DOM check. [The browser boundary](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) confines that response to its command and excludes it from authentication replies.
3. **Separate historical edits from repair needs.** [Action context](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) version 4 marks each changed historical edit with `requires_repair`. Query controls are withheld while any such field remains changed. Context still carries exact historical user sources and the complete current request. Inspection is a point-in-time observation, so native execution continues to revalidate the query independently.
4. **Make repair mandatory in the next contract.** [Form input](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) version 7 computes `required_repairs` from fresh bound values and the retained expected values. A mismatch is allowed only on a previously edited, unpreserved target, and that target must remain editable in the selected form. The [proposal decoder](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormProposal.swift) requires every listed field to receive a new source-backed edit before any edit stage is accepted. An omitted repair or a proposal to preserve its newly observed wrong value is rejected. A justified question or unavailable result still performs no input.
5. **Retain the full effect chain.** New contracts keep every other earlier criterion and explicit preservation as before. The version-3 combined continuation keeps all original operation IDs plus the new operations. Repair does not alter earlier journals, receipts or goal revisions. The native GET query path supplies no value-drift exception and checks every current required value, submission membership and original receipt before loading.
6. **Interpret repairs under the current goal.** The action schema is now `browser_research_action_v4`; the form schema is `browser_form_plan_v6`. The form prompt requires interpretation of current user sources and accepted answers instead of copying hidden historical values. An explicitly revised city can therefore be entered as a new goal-backed operation. These prompts and model decisions are unqualified.

The earlier native bounds remain: one retained form/document, sixteen fields, eight edits per stage, thirty-two stages and sixty-four accumulated input receipts. There is no new inference worker or model configuration. This checkpoint adds one bounded native inspection before planning on a completed retained form; no runtime performance claim follows from source review.

## Prepared coverage — not executed

Eight new methods in [the repair tests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormRepairTests.swift) specify:

- Default driver recovery from a reset category, followed by a city edit and combined query, preserving original search/input history and independently counting page input events.
- Refusal to omit a mandatory repair, preserve its incorrect value, or prepare the old query after read-only extension. Question/unavailable proposals remain effect-free.
- Multiple changed criteria requiring distinct new edits, with all original and repair receipts retained for submission.
- A field explicitly preserved by a later stage remaining protected even though an earlier stage edited it.
- Refusal to plan from missing native receipts when values happen to match.
- Pause during native inspection, joined completion and fresh observation after explicit handback.
- Recovery from a failed verified repair-receipt write using the same operations without duplicate input.
- An accepted city answer controlling the new repair while historical input receipts retain the original goal revision.

The existing required-object/preservation regression keeps its replacement and preservation failures. Its old assertion that a changed unpreserved edit can never be inspected is replaced by the mandatory-repair cases. These are controlled planner choices and authored assertions, not model or native runtime evidence. No held-out data was used.

## Remaining repairs

1. **Reconcile replaced required objects and changed shapes.** Retain the historical attempt while explicitly mapping an outstanding user requirement to a newly observed native target. Label/value equality must not impersonate the old object or its receipt. This checkpoint only repairs value drift on a still-valid object.
2. **Revise or remove obsolete criteria and revoked preservation.** Releasing a requirement needs an explicit source-bound change under the current complete goal. Automatic omission must not become permission to discard it. The current repair path requires every changed criterion to be edited; it cannot deliberately remove a criterion from submission.
3. **Replan changed unsent or partly attempted work.** This repair starts from a completed stage. A changed pending stage, a reset during another stage's effects, or more required repairs than one stage supports still needs per-step reconciliation without recreating receipts or replaying uncertain input.
4. **Finish document/login transitions and parent recovery.** Provider windows, host/phone handback after lost native authority, task-level preservation across pages, durable goal/action recovery, archived evidence and cleanup remain open.
5. **Finish browser and result capabilities.** Broader date/location/party interpretation, custom widgets, POST/dynamic/embedded forms, offer association, availability, fees, distinct counts, ranking, public source links and complete answers remain unqualified or incomplete.
6. **Qualify once authorized.** Typecheck/build and bounded native/model tests must precede the retained travel/concert/movie live-site scenarios. Keep the 8 GB Mac target and defer performance work until correctness repairs are done. Alternate models and desktop RTX 3080 adaptation remain authorized; SSH connectivity is unresolved.

## Source verification

Eleven changed Swift files passed syntax parsing only. Four JavaScript syntax checks covered the fixed production dispatcher and the three new fixture mutation scripts. The Xcode project property list and new source registration were checked. The default and [focused inventories](browser-form-repair-inventory.json) match 1031 and 348 method identifiers. Local documentation links and whitespace were checked.

No typechecking, builds, test/assertion execution, model inference, app launch, computer use or real-site E2E ran. The installed application, runtime/model assets and performance stash remain untouched. Source checks do not establish working natural-language behavior or close the product goal.
