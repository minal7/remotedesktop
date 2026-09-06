# Local browser controls must control the host task

Parent source: `045562d`. Status: source implementation and regression registration only. No builds, test execution, inference, app launches, rendered UI checks, computer-use activity or account interactions. Performance work and live website scenarios remain deferred.

## Failure and source change

The owned browser's Stop button called only `ComputerUseOwnedBrowser.stop()`. It invalidated browser ownership but did not durably stop the host task, cancel other capabilities or update the phone's task lifecycle. The browser also lacked local takeover and handback controls.

The browser now displays **Take control**, **Let AI continue**, and **Stop AI** according to a host-published task snapshot. Takeover enters the existing host pause/intervention path, including invalidation of held approvals and cancellation. Handback requires the current paused presentation and an authorized task owner, then uses the existing Resume path, prior-executor join and fresh browser-page reacquisition. Stop closes the action gate before persistence, durably cancels the task, cancels execution/approvals and stops browser activity. Failure to persist Stop still closes effects and reports the storage failure.

The snapshot binds the task, sender/session, authorization/transport generation and execution token in host state. A run scope survives a pause, while its presentation identity changes with phase, remote control revision or Resume availability. Starting another run replaces the scope. An old Resume presentation cannot authorize handback, and an old run's buttons cannot affect its successor or a replacement task. Progress messages do not rotate an otherwise identical snapshot.

This distinction also handles a real UI ordering issue: the input monitor can pause a working task on mouse-down before the Stop button's mouse-up handler executes. Stop remains valid for that same paused run. It is not valid after another run begins.

The host's tools cache the current snapshot and handler for lazy browser creation. Handlers retain the manager weakly. Host activity and peer-authorization changes refresh the presentation, and every local action refreshes/revalidates it again before acting. Closing the actual owned window requests task Stop before releasing the browser. Foreign/stale window-close notifications are ignored. Programmatic close remains the existing teardown operation.

## Durable Stop and phone delivery

Local takeover and handback do not allocate the phone's numbered control revisions. Local Stop needs an absorbing cancelled record: otherwise the phone could ignore an older terminal update while waiting for a newer Pause/Resume acknowledgement, and a later status-only acknowledgement would not complete its UI task.

`ComputerUseTaskLedger.cancelLocally` uses the existing control reducer to commit Cancel at the next revision. Cancel remains absorbing, so collisions with or later delivery of phone controls cannot undo Stop. Those controls receive the durable stopped result at their acknowledged revision through the existing cancelled-control replay path. At `UInt64.max`, local Cancel may make the terminal transition at the same exhausted revision; remote controls retain their ordinary stale/duplicate rules. Scope mismatch still rejects the operation, and the first durable terminal result remains authoritative.

## Prepared regression coverage

Four methods are added:

1. A local Take control / Let AI continue / Stop AI sequence through the browser handler and real host manager. It rejects stale presentations and old runs, permits Stop after the input monitor pauses that same run, persists Stop and returns it for a delayed higher-revision phone Resume. Local takeover/handback leave the remote counter unchanged.
2. Authorization loss while paused disables and rejects local handback. Restored authorization supplies a new valid presentation. Old task buttons and a foreign window-close notification cannot control a replacement task.
3. A controlled terminal-storage failure while an executor ignores cancellation. Local Stop removes controls, closes the effect gate, blocks the late attempted action and reports failure rather than a persisted stopped result.
4. An exhausted remote revision, including a mismatched owner, durable local Cancel, reconstruction and a duplicate Resume that still returns stopped.

The new local-control tests construct an unpresented browser owner without creating its WebKit view. They exercise state/handler composition with scripted executors, not actual clicks or website tasks. Existing browser handback and selected control/ledger cases accompany them in the [focused inventory](browser-local-controls-inventory.json).

Source registration matches **569 default / 27 focused** method identifiers, and whitespace checks pass. All changed Swift files were already in the project. This is not compilation, test execution or visible-control qualification.

## Remaining repairs and qualification

1. **Unify causality for local and phone handback.** Local takeover/Resume currently inherit the host's existing unversioned intervention semantics. A delayed higher-revision phone Resume may supersede a later local takeover; a duplicate phone Pause may reapply the durable remote paused state after local handback. Add a reviewed host intervention epoch/acknowledgement (or equivalent protocol), preserve it through reconnect/restart, and test both arrival orders. Do not let local Pause/Resume simply consume the phone's counter. The new durable Stop is absorbing, but does not solve this nonterminal ordering problem.
2. **Qualify actual controls and accessibility.** Verify labels, enabled states, mouse-down/up intervention ordering, keyboard access, window closure, approval invalidation, prior-executor unwind and effect exclusion in the signed host and on the phone. Check compact window layout; no UI was rendered in this repair.
3. **Complete browser login and task continuation.** Popup/provider login remains blocked. Bind fresh targets and remaining goal obligations after handback without replaying uncertain or completed effects. Confirm account/login state independently and retain secrets outside model observations/logs. A button click authorizes continuation; it does not prove sign-in success.
4. **Complete browsing workflows.** Navigation/search, date/location controls, extraction and source-backed travel/concert/movie results remain unqualified. Compile/run the controlled gates only when execution is authorized, then follow the separately required permission process for real websites. Keep performance and the 8 GB target in the later phase.
