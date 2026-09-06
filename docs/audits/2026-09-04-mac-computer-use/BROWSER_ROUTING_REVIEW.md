# Initial browser form routing repair

Status: source implementation and regression selection only. No compilation, XCTest, app launch, inference, computer-use interaction or live website search was performed for this change. Correctness repairs take priority; further performance optimization is deferred by the user.

## Problem and principle

A capability declining a task is different from a task failing after that capability has accepted responsibility for it. A whole request may be handed to another executor only when the first capability explicitly declines before effects. An error, a partial observation or an unresolved effect cannot authorize reconstructing the request elsewhere.

The native text executor inspected an already-open owned browser before the desktop executor could consider the current user request. `ComputerUseBrowserTextTarget.fields()` throws `unsupportedDocument` when a visible editable control has no usable label, more than sixteen fields are found, or observation limits are exceeded. That error escaped the initial native route, so even a broader request unrelated to filling this form could be stopped by the incidental page layout.

A catch for `unsupportedDocument` around the native executor would be incorrect: the same error also occurs in transport-size checking, malformed field snapshots and preflight. Errors after an attempted edit must remain bound to the original task and its journal.

The source review also found that no effects in the current attempt does not prove the task is fresh. A replacement executor may lack an in-memory contract while an earlier executor's edit journal remains. The host ledger already rejects replay after host restart, but the native capability also needs to enforce its own durable boundary before any decline.

## Implemented boundaries

| Stage | Behavior |
|---|---|
| Fresh browser field discovery | `fieldsIfSupported()` returns a decline only for the isolated host script's explicit `unsupported` or `limit` status, without a partial field array. The existing throwing `fields()` API is retained for callers requiring a supported form. |
| Successful but empty discovery | Remains a no-effect native decline. It cannot report the broader goal complete. |
| Stale page, ownership/focus change, cancellation, malformed data or unknown reply | Remains an error. A `stale` script reply now maps to `pageChanged` explicitly. No generic error is caught for fallback. |
| Native entry and return from discovery | Cancellation and the host action gate are checked before discovery and after its asynchronous return, including a no-form result. A takeover cannot become a desktop handoff. |
| Any native decline | Check for an existing text journal without creating storage or following its symlink. Any entry, including corrupt or dangling data, prevents fallback with `journalMismatch`; directory/permission errors remain errors. Only a proven missing entry allows decline. Normal recovery retains strict journal loading. |
| Exact-text preflight | An incompatible planned value stays an explicit unable-to-complete result. Another executor cannot bypass that failed constraint. |
| Retained task or clarification answer | Uses the retained task/re-observation path. It never calls initial discovery to recover from an error or routes a short answer as a fresh desktop request. |
| Desktop handoff and resume | The existing coordinator retains task ID, exact current request, separate model context and typed conversation. The selected desktop instance handles same-task continuation; no second form observation is requested. |
| Uncertain input | The original native task and dispatch journal remain authoritative. No desktop load, second planner proposal or duplicate input is permitted. |

Implementation: `host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift`, `ComputerUseNativeTextExecutor.swift` and `ComputerUseTextStepStore.swift`. The coordinator's error propagation and scoped continuation rules remain in place.

## Deferred validation

The four new XCTest methods use controlled local WebKit fixtures and a recording desktop double:

1. An empty, unlabeled or oversized form permits the complete request to reach the desktop route, preserving task/context separation through repeat execution. No form planning, edit journal or input is allowed. The double returns unable-to-complete; this is a routing assertion, not a flight-search result.
2. An already-closed action gate, cancellation during discovery, takeover during discovery or loss of browser ownership prevents fallback.
3. A declined clarification answer or a newly unsupported retained form cannot enter desktop routing.
4. An input handler that rejects the requested value leaves the native task uncertain. Repeat execution must not rediscover, replan, load desktop tools or emit another edit. Recreating the executor and then declining through the planner or unsupported form must also remain blocked by the persisted attempt.

A fifth new method covers the journal probe: a missing directory is not created, and a directory symlink, non-directory path or wrong permissions cannot appear as empty storage. Existing storage regressions now assert that attempted, corrupt and dangling journal entries all prevent a fresh decline. Other regressions were extended to run incompatible-value preflight through the production coordinator and to require propagation of native `unsupportedDocument` and `pageChanged` errors.

The [focused inventory](browser-routing-inventory.json) selects exactly 23 source methods, including existing route identity, continuation, cancellation, storage and whole-form checks. The default inventory selects 405 methods. Both source inventories and `git diff --check` pass. These checks do not compile or execute Swift and are not acceptance evidence for the changed behavior.

When execution is authorized, run the focused selection first and retain exact results. Then qualify production composition as appropriate. Real flight, concert and movie searches remain subject to the user's explicit future permission.

## Still open

This fixes an initial routing obstruction. It does not implement date controls, submission, result extraction, whole-goal completion proof, general AX form support or the downstream desktop planner's missing capabilities. Those remain on the correctness repair list. Preserve all request constraints and independently verify every requested outcome before reporting a future search complete.
