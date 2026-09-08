# Completing an interrupted native change notification

Source checkpoint after `3d05a8d`. The [working repair list](../../../TODO.md) remains open; runtime and model qualification remain paused.

## The underlying distinction

A scalar or dropdown edit consists of several observable operations: set the value, dispatch `input`, dispatch `change`, then independently check the result. The old native dispatcher stored an attempt before the setter and a completed receipt after the final notification. If an `input` handler revealed login, changed a constraint or replaced a field, the dispatcher correctly withheld `change`. But it retained no distinction between that provably missing notification and an arbitrary incomplete input attempt.

Consequently, Resume could not finish a dropdown after login even if the original control, expected value and all requirements remained intact. Repeating the setter and `input` would duplicate page events. Calling the existing attempt complete would omit a required notification. An equal value alone proves neither event.

The repair retains the boundary after the `input` dispatch returns and before `change` begins. It can complete that exact missing notification under the original operation ID. It does not replay the setter, selection or `input`, and it never equates delivery with a verified outcome.

## Source changes

1. **Keep native phase evidence.** [The isolated DOM dispatcher](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) records pending change data only after the original scalar/choice `input` dispatch returns. It retains the original binding, expected value, document URL, document and input-ledger identities, earlier field requirements and any distinct copy source. The private pending map is bounded by the existing operation limit and clears whenever its corresponding input ledger clears. Values stay in the isolated native context and do not enter model context, journals or replies.
2. **Use one implementation for the initial and deferred tail.** Both paths synchronize mutation records, require the original document/ledger/URL and current authentication clearance, check the original control and expected value, and recheck required fields and a distinct copy source. The edited field's own old value is excluded from retained constraints because its new expected value is checked separately. An `input` handler changing explicit preservation now also withholds `change` before further page code runs.
3. **Consume the missing notification before dispatch.** Native completion deletes the pending record and records a change attempt before dispatching the original control's fixed `change` event. A throwing or interrupted dispatch cannot retry that notification. A returned dispatch records the original completed receipt. If the change handler alters the result, later outcome verification still fails. There is no new payload, target, setter, selection, input event or operation identity in this continuation command.
4. **Confirm the disk attempt before the effect.** [The journal store](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseTextStepStore.swift) adds `confirmPendingAttempt`. It requires a valid unretired journal whose first unfinished step is attempted/uncertain, the caller's active execution lease and an exact saved-state comparison. It synchronizes the journal directory to resolve a previously visible but unconfirmed rename. It cannot create an attempt, change a status, clear a retirement marker or refresh an out-of-date expectation. A poisoned writer still needs a fresh store.
5. **Finish before independently checking recovery.** [The execution engine](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseTaskExecution.swift) accepts an optional capability callback only for an already attempted/uncertain step, after dependencies and unchanged constraints are checked and while its execution lease remains held. It passes that step's original effect identity. Ordinary execution is never called again for recovery. After the callback, ownership and all original postconditions/receipts are checked as before. A missing native phase record cannot authorize an input retry.
6. **Connect both production paths.** [The text capability](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseTextTask.swift) carries the callback to the engine. Both [research form stages](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) and [the current-form executor](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseNativeTextExecutor.swift) confirm their exact saved attempt before asking the retained target to finish the pending notification. Research stages retain their original contract, per-stage store and history. The current-form executor keeps its original planned task and target. Neither asks a model to regenerate the action.
7. **Join a cancelled native continuation.** The target waits for an already-dispatched completion call to return, or for its browser to be released, before propagating cancellation/timeout/control-loss errors. That keeps the enclosing execution lease in place through the native call. A late completed receipt remains historical evidence; it cannot override Pause or claim the task completed. The existing explicit login handback requirement still governs research Resume.

The native protocol gains an internal `finishPendingChange` command; model prompts and response schemas do not change. Old full input receipts remain ordinary completed receipts. A missing record, uncertain earlier phase, changed value, replaced original object, changed metadata, lost ledger or invalid saved state remains unresolved. No unrequested account action, credential handling or navigation is introduced.

## Prepared coverage, not executed

Ten methods in [the pending-change tests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserPendingChangeTests.swift) specify:

- Research-driver login between the original dropdown's `input` and `change`, explicit handback, original step IDs, no replanning and exactly one of each event.
- The current-form executor continuing its original task under its action gate, including repeated same-ID execution without repeated notifications.
- Refusal after changed selection, replaced control, changed option constraints or a replaced input ledger.
- An earlier preservation invariant blocking continuation before the native callback.
- The inline native tail withholding `change` after an `input` handler changes preservation, then completing only after the exact preserved value is restored and control is returned.
- A completed change handler undoing its result, leaving the stage uncertain across repeated Resume without another event.
- Pause during the native completion call, exclusion of another execution owner, release after native completion, and subsequent handback without duplication.
- A research journal write failing after native-tail verification, with fresh recovery from the original receipt and no repeated input.
- Exact attempted-state confirmation, missing lease refusal, poisoned-writer refusal, fresh-store resolution, stale comparison refusal and rejection of planned/verified/retired states.
- The same native continuation for date and number inputs.

Page callbacks record input/change counts independently, and the positive query case checks the page-recorded event order before navigation can cancel outstanding requests. These controlled native/planner fixtures are not actual-model, provider or live-website qualification. Existing scalar/choice drift tests continue to specify no replay where no completion callback is installed. No held-out set was read or run.

## Checks performed

Seven Swift files passed syntax parsing only. Production DOM JavaScript and seven fixture variants passed JavaScript syntax checks only. The Xcode project property list and test registration were checked. The default and [focused source inventories](browser-pending-change-inventory.json) match 1070 and 387 method identifiers. Documentation links and whitespace were checked.

No typecheck, build, assertion/test execution, model inference, browser/computer-use run or installed-app replacement occurred. This checkpoint created source and documentation only, with no disposable runtime/build output. Performance work, the 8 GB qualification target and later RTX 3080 model adaptation remain deferred to their agreed stages.

## Remaining repair order

1. **Current-form storage recovery.** Unlike a research form stage, `ComputerUseNativeTextExecutor` retains a task whose callbacks close over one journal-store instance. A failed write poisons that store, and same-ID execution reuses the retained task. Reopen storage around the original immutable task/target, with exact compare/load and execution exclusion; do not rediscover fields or regenerate the plan to recover a failed write. Audit cancellation and native completion joining across its other read/input/query paths as well as this newly joined tail.
2. **Other incomplete native phases.** A failure before the returned input boundary or after a change attempt cannot use this capability. Preserve the original operation and provide explicit reconciliation without inventing absence, completion or retry permission.
3. **Completed delivery with changed outcomes.** A fully delivered action may never have satisfied its result, or a website/user may subsequently alter it. Retain delivery history separately from current-goal requirements, and justify any new correction from the complete goal. A new operation ID alone is not that justification.
4. **Required-object and requirement changes.** Keep historical receipts while explicitly binding remaining intent to replacement objects. Support source-backed release/revision of obsolete criteria and preservation; omission is insufficient. The preceding [prefix repair](BROWSER_FORM_PREFIX_REVIEW.md) still requires one-to-one mappings for unfinished edits.
5. **Whole browsing and login continuity.** Finish document/provider transitions, durable parent reconstruction, account handback qualification, custom controls and JavaScript/POST forms, travel/concert/movie result predicates, availability/fees and public source links. A repaired native notification is an intermediate action, not a verified research answer.
6. **Qualification.** After development readiness and the user's explicit authorization, run the controlled suites before model and provider qualification. Separate application failures from model interpretation failures before selecting or adapting another model. The RTX 3080 authorization remains recorded, but SSH and remote hardware are still unverified. Real-site E2E and Mac performance measurements remain paused.
