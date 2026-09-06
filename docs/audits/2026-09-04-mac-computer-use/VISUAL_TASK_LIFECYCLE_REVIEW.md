# Visual task lifecycle repair

Status: source implementation and regression selection only. No build, test, model run, app launch or computer-use interaction was performed. Further performance optimization remains deferred until correctness repairs are complete. Real flight, concert and movie scenarios still need the user's explicit future permission.

## Findings from current source

The visual executor already retains history, performed-action count and an uncertain-effect flag across ordinary cancellation. The original audit's fresh-state-on-every-resume description is no longer accurate for this current source. Four other boundaries still needed repair:

1. `executeRetainedLoop` cleared the checkpoint when returning completed, unable-to-complete or clarification. A repeated delivery with the same task ID could activate the model and execute the request again.
2. `executeResolved` accepted changed text under the same task ID, either resetting state or comparing canonically equivalent Swift strings as equal. Exact literal payloads require a byte-level identity check.
3. An ordinary repeat of a task waiting for approval cancelled its pending endpoint and discarded the approval before planning again. A retry must not silently replace its exact pending action/token.
4. MainActor serialized individual synchronous segments but did not prevent a second execution call entering during an await. An overlapping call could replace the checkpoint or cancel resources still owned by the first.

The host manager, capability coordinator and durable ledger already enforce important outer admission rules. Those do not justify weaker identity and replay behavior inside a reusable executor. Each layer must preserve the task it has accepted.

## Implemented behavior

| Boundary | Behavior |
|---|---|
| Execution/approval entry | A shared in-memory running guard rejects overlap before state changes or runtime work. Explicit cancellation remains available; callers join the active call before starting replacement work. |
| Same task ID, different request bytes | Reject with `taskChanged` before cancelling an endpoint, discarding approval or activating a model. Whitespace and Unicode normalization differences remain significant. |
| Same task ID and exact request, terminal result | Return the prior terminal delivery result without planning, observation, activation or effects. A caller already cancelled still receives cancellation. |
| Same task awaiting approval | Return the exact pending message, action and continuation token. This does not refresh or re-authorize the action; host approval still checks the current effect boundary. |
| Same unfinished task | Retain the existing checkpoint and re-observe before further actions. An uncertain effect continues to require reconciliation. |
| New task ID | Use the existing replacement/cleanup path and create a new checkpoint. A distinct task can legitimately repeat the same user request. |
| API without a caller-supplied ID | Generate a UUID per invocation rather than sharing the literal ID `legacy`. |

Implementation is in `host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift`. The terminal cache retains only the current executor's current task. The durable host ledger remains responsible for older task identities and host restart replay; this change does not implement a durable visual effect journal.

## Deferred validation

Three new source methods cover terminal replay after model shutdown, independent requests for the same operation, cancellation before cached replay, exact-byte identity changes and concurrent entry during a held app-open callback. The concurrent fixture holds only its first callback, so unintended additional app-open calls fail assertions instead of hanging the regression.

Three existing methods now also cover clarification replay without a second route proposal, unable-result replay without another capture/runtime call, and approval replay/changed-goal rejection before using the original one-use token. The [focused inventory](visual-task-lifecycle-inventory.json) selects 15 exact methods, including previous continuation cancellation, task coordinator and host teardown coverage. It matches source, as does the 408-method default inventory. `git diff --check` passes. None of these facts proves Swift compilation or runtime correctness; execution remains paused.

## Next correctness work

The visual loop still treats each exact TYPE payload and ENTER history marker as one-shot within a task. Removing those checks without a real step identity would permit duplicate effects; leaving them as the final design prevents legitimate repeated input and multiple searches. A model proposal count, a fresh screenshot or a focus change is not evidence that the user requested another effect.

1. Compile the entire current request into ordered typed outcomes/operations, with explicit constraints and dependencies. Preserve supplied bytes separately from generated or observed data. Reject an incomplete contract before its first effect.
2. Bind each operation to the intended application/document/element, its step ID, payload version and adapter-owned pre/postconditions. Use the existing shared `ComputerUseTaskContract.effectIdentity` and transaction engine rather than raw history strings for repetition control.
3. Implement the browser search/submission and result-observation adapters needed by travel and ticket workflows, including navigation/document changes. A verified fill alone cannot prove a submitted search or the resulting availability/price.
4. Route verified step progress and remaining outcomes through normal execution, pause/resume and approval continuation. Reconcile attempted effects before advancing; prove every requested final outcome before reporting completion.
5. Qualify repeated values in distinct targets, repeated submissions as distinct steps, interruption at each boundary, unchanged constraints and uncertain-result recovery. Keep independent full-goal and intermediate-effect oracles; do not infer success from a model stop action or a few fixture passes.

These remain F01/F02/F03/F04/F10/F16/F24/F26 work. This lifecycle change does not close the whole-goal or visual-step findings.
