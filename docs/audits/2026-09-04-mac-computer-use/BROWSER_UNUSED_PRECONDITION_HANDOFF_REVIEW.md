# Unused captured edit preconditions after handback

Source repair; execution pending. This extends the [unobserved initial intent repair](BROWSER_UNOBSERVED_FORM_HANDOFF_REVIEW.md). No build, typecheck, assertion, app, browser, model or account-login execution occurred.

## First-principles distinction

Reading a field's default, promising to preserve a field, verifying a desired value and dispatching input are different events. The preceding repair released only an initial plan with no private observation. It therefore still stranded an otherwise unused preparation when the first field read had completed before a manual login redirect.

A default captured only as the precondition for a proposed edit is not a user-requested invariant. The form planner receives source-bound desired values and public metadata; it cannot copy or infer the hidden current values. On a different page, fresh discovery can establish the new edit preconditions. This reasoning does not apply to preservation/read duties, retained criteria, earlier stages, revisions or uncertain execution.

Releasing a captured default also requires closing its old adapter. Merely removing the owner's preparation would leave any other retained reference capable of attempting the old input. Conversely, a failed or cancelled attempt must not turn an adapter back into an unused one.

## Adapter lifetime and authority

The [text adapter](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) now keeps two irreversible host-side facts: whether it has issued form authority and whether an unused preparation has retired it.

Authority is marked before input dispatch, desired-value verification, query capability export, clarification transfer, preservation capture, extension/revision, criterion-repair binding, pending-change completion and native input retirement. The mark precedes awaits and exports. Failure, cancellation and a negative verification result do not remove it. Both sides of a clarification transfer retain the mark, so copying a binding cannot create another unused adapter.

Unused retirement is permitted only before any such authority and without a preservation guard. It does not contact the stale document. Afterwards, adapter validation rejects access before native dispatch, including reads, input, verification and transfer. Validation checks retirement again after browser/presentation checks to handle synchronous reentrancy. The preparation itself also rejects reuse, review, revision and recovery after retirement.

This is local capability accounting, not a replacement for native effect receipts. Any adapter that reached an execution-related path remains on its existing native/journal reconciliation path. No absence claim is inferred from a failed input or missing receipt.

## Captured initial preconditions

The [retained read](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOMReadCapture.swift) exposes the native document and ledger identity only for a successful, nonempty initial `formFields` reply. The native first discovery creates a fresh field ledger; its identity is not a claim about later effects. The adapter's irreversible authority accounting supplies the separate later-use check. Unknown initial callbacks, ordinary initial-read failures and pending callbacks cannot qualify.

The [preparation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormPreparation.swift) still requires an initial frame with no parent, continuation, revision, baseline inheritance, criterion repair, amended review, retained-field purpose, preservation source or read source. Its planning page must be metadata only. No preservation capture may have started. A started binding read must have settled; the owner cannot retire it while its callback is pending.

A successful initial read can qualify even when cancellation prevented its waiter from adopting the values. If the target did adopt fields, its native document/ledger must still match that first read. A completed preparation also qualifies when its hidden defaults remain unused edit preconditions. No captured value is copied to the replacement page or converted into a desired-value proof.

The [owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) retains the preceding exact handback rule: successful explicit Resume, a different native DOM document in the same context, current source policy, a fresh page observation matching the handback document, and fresh native validation. Final goal, Pause and preparation-identity checks precede retirement. Retirement of the old adapter and publication of its historical purposes occur synchronously in the serialized owner operation.

The owner then clears the unused preparation. The driver can reconsider the complete current goal and prepare fresh fields. This creates no execution stage, query, receipt or retirement journal. Earlier histories and duties remain intact. Cancellation before retirement leaves the preparation available for another explicit handback; cancellation after publication does not undo the already-retired adapter or its history.

## Planning context

[Action context](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) version 29 replaces the source-only version 28 field with `unused_form_intent_history`. The shared record now distinguishes `observation=none` from `observation=initial_edit_preconditions` and reports `values_observed` truthfully. `old_adapter_retired` is true for owner-published records. `input_dispatched` and `current_field_verification` remain false.

The context retains public historical purposes and exact user-source spans without private defaults, native identities or old control bindings. It remains bounded, ordered and tied to the original/retirement goal ancestry and browser context. Instructions require fresh interpretation, scope and field preparation; neither captured defaults nor retired intentions count as completed criteria, authentication or task success.

## Authored verification, unrun

Five new methods in the [preservation suite](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift) cover:

- A fully prepared unused form surviving manual document change through fresh defaults/targets, rejecting its old proposal, preserving the complete goal and initial search, and producing the first actual stage only after fresh input.
- A pending binding callback withholding retirement, followed by eligibility only after its cancelled waiter joins.
- Permanent adapter retirement on the still-current original document, rejecting reads, input, desired-value verification, transfer and preparation reuse before native dispatch.
- Input cancellation retaining the adapter's used state both during dispatch and after native completion is joined.
- Desired-value verification and failed clarification transfer retaining their issued authority without requiring an input effect.

Existing cases now distinguish captured preconditions from unobserved intent, retain uncaptured preservation duties, check initial-read identities and pending state, and exercise cancellation during final handback recovery for both unobserved and completed preparations. Version/history assertions use the new context.

Six changed Swift files pass parse-only checks. Default/focused source inventories select 1718 / 1035 methods, with five additions and no removals. These checks establish syntax and source registration only. No native callback, assertion, model or real-site outcome is established.

## Remaining work

This handles unused initial edit defaults. Captured user invariants, read duties, prior desired-value proofs, receipts, uncertain input, revisions, dropdowns and selections still require explicit reconciliation across document/account changes. Provider semantics and explicit goal supersession cannot be inferred from matching labels or values.

The adapter mark relies on the audited production entry points; new effect or capability-export paths must participate. Qualification still needs native timing/reentrancy, source and goal changes, host/phone handback, real login redirects and durable process recovery. The global navigation-source completion restriction remains in place.

Continue the [repair checklist](../../../TODO.md). Full natural-language task completion, travel/concert/movie scenarios, model qualification or replacement, training, resource measurement and the 8 GB target remain unverified and deferred to their authorized stage.
