# Preserve approved-action evidence across cancellation and recovery

Parent source: `bbdc0fe`. Status: source changes and fixture registration only. No build, test execution, model inference, application launch or computer-use activity ran. Performance optimization and real-site acceptance remain deferred.

## First-principles problem

Stopping a task and learning what an already-approved action did are different events. The inner MCP executor can return a successful helper result after concurrent cancellation. The capability wrapper previously turned that return into `CancellationError`, and the host manager discarded a returned result whenever its task was cancelled or its execution token had changed.

Simply removing those checks would create a different error: an old completion could clear a newer task, reopen automation, or replace the durable Stop response. The task ledger deliberately preserves its first terminal result. Pause also retains the old task for Resume, which previously could enter ordinary execution again after an approved effect whose result was discarded.

The repaired design records an approved-action handoff and its confirmed result independently from task completion and UI ownership.

## Durable record

`ComputerUseTaskLedger` now has an optional `ApprovedActionRecord` containing the exact approval fingerprint, handoff timestamp, bounded confirmed response and a digest of the full response. It adds no copy of tool arguments, prompt text or field contents. Result text follows the existing 4,000-character terminal-response bound; the full response digest distinguishes conflicting results even when their visible prefixes match.

Before invoking an approved MCP continuation, the manager claims this record durably. The ledger requires the already-claimed, started task, exact sender/session, matching call task ID, approval-required risk and exact fingerprint. A paused, cancelled or terminal task cannot acquire its first approved-action handoff. An existing handoff is returned as existing, even if a later caller presents another generation or call; it never authorizes a second dispatch.

The timestamp records the attempted handoff to the approved continuation. It is not proof that an OS event or helper mutation was posted. Failure after that boundary is conservatively unresolved until a confirmed result exists.

A successful response can update only the exact claimed fingerprint under the same task/sender/session. Repeating the same full result is idempotent; a conflicting result or foreign scope is rejected. Confirming the action leaves the task's response, terminal outcome and control revision untouched. Thus Stop can remain the terminal response while the separate action record proves what the helper later confirmed.

Legacy task records without the new field remain readable. Records with an action but no claimed/started bound task, or with only one of the confirmation response/digest pair, poison the ledger. Existing atomic commit failure behavior remains: a failed claim cannot authorize dispatch, a failed confirmation cannot authorize a reported success, and further in-process work is rejected after persistence failure.

Unconfirmed approved-action records are retained even when their tasks have a terminal response and would otherwise age out of pruning. Evicting such a record could erase the only host-level evidence preventing replay of an unresolved consequential handoff.

## Manager and wrapper behavior

The capability wrapper preserves a `.completed` return from the approved MCP continuation despite concurrent cancellation. Other late continuation results still undergo cancellation checks.

The manager records a successful approved result before checking its execution token. Only the matching current token can accept the task result, change activity, clear execution state or emit normal completion/status messages. A late result for a stopped or disconnected task therefore updates its exact durable action record and does not produce another terminal message or alter a newer task.

Resume still joins the previous execution before doing anything. It then reads the approved-action record before invoking native or desktop execution. A confirmed result completes the existing MCP task from its record. An unconfirmed handoff returns an explicit unable outcome and does not replan or repeat the action. An accepted task recovered after host restart uses the same record instead of the generic suggestion to send the request again.

The existing MCP contract treats an approved action as a terminal operation. This record does not introduce a general multi-action task ledger or prove every component of an arbitrary compound request.

Approved-action failures no longer claim that nothing was performed. They report that the result was not confirmed and that the action will not be retried automatically. This avoids encouraging duplication after an ambiguous helper error.

## Prepared verification

Eight new methods cover:

1. A confirmed result persisted after Cancel, exact receipt reload, unchanged Stop response/outcome/revision and refusal to authorize another generation's action.
2. Unclaimed and foreign results, incorrect fingerprints, idempotent confirmations and conflicting full responses including identical bounded prefixes.
3. Storage failure before the handoff claim and after it: no unpublished state becomes authoritative, the live ledger remains poisoned after storage recovers, and reload sees only the prior committed state.
4. An old cancelled task with an unconfirmed action surviving pruning, alongside a legacy task without the new field.
5. Pause and immediate Resume through the production capability wrapper while an approved fixture action is pending, then a late successful return; Resume uses that confirmation without another execution or effect.
6. The same interrupted handoff with no confirmed result; Resume cannot replan or repeat it.
7. Stop followed immediately by a newer prompt; the old confirmation remains recorded without replacing Stop or changing the new task's paused state.
8. Transport shutdown during an approved action; late confirmation remains available after ledger reload with only the original terminal response emitted.

The manager methods use fake transport, a controlled approved-continuation fixture and the real capability wrapper/task ledger. They do not launch Mail, send email, synthesize desktop input or invoke a model.

The [24-method focused inventory](approved-action-record-inventory.json) also selects existing task-ledger, control, approval, transport and MCP result-preservation regressions. The default source inventory grows from 510 to 518 methods. No project source references change.

## Validation and remaining work

Source inventory verification matches all 518 default and 24 focused identifiers. `git diff --check` passes. These checks prove source registration and whitespace consistency only; compilation and execution remain paused.

- Compile and run all focused methods when permitted, then qualify actual approved helper effects through the signed host and mobile client. A fixture's successful return does not prove real Mail mutation or transport behavior.
- Expose retained action evidence after a task has already terminalized through an explicit client/history interface. This patch keeps Stop/disconnect replies stable and records late confirmation locally; it does not yet add a wire field or display the separate record on the phone.
- Reconcile unresolved handoffs with capability-specific evidence. A handoff persisted before dispatch may ultimately have performed nothing, but the generic continuation API does not prove that distinction. Do not automatically retry until that uncertainty is resolved.
- Preserve the same evidence across shutdown/crash boundaries in the underlying helper and mutation ledger. A crash after a real effect but before confirmation remains unresolved; this patch does not claim exactly-once distributed execution.
- Define retention and operator-resolution policy for unconfirmed records without making old task IDs executable again. Their conservative retention is deliberate; resource budgeting belongs to the later performance phase.
- Continue the general task/step ledger, native AX/visual receipts, whole-goal outcome verification and natural-language qualification. Travel, concert and movie real-site scenarios remain subject to explicit user permission. No thermal or 8 GB qualification follows from these edits.
