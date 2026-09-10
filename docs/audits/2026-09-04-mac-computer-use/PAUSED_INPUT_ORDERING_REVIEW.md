# Order paused manual input before remote handback

Source repair; execution pending. This follows the [Resume admission repair](RESUME_ADMISSION_REVIEW.md). No build, typecheck, assertion/test run, app/browser launch, inference, real-site task or SSH connection ran for this repair.

## First-principles finding

A phone's Resume command describes the handoff state the phone observed. If the person continues typing or moving the mouse on the Mac after that state, the older command cannot silently authorize automation against the changed situation.

Previously the manager's synchronous interruption callback did nothing once active/pending/approval ownership was closed, and its actor callback ignored an already-paused task. Consequently continued input during a login handoff did not advance the host control epoch. The prior admission repair protected input after Resume began, but did not account for input that preceded it.

## Native occurrence tracking

The [action gate and manager](../../../host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift) now retain a private paused-input scope and monotonic generation. The scope belongs to the paused execution's task, sender and session. A reconnect or authorization refresh of that same retained task preserves unacknowledged input. Leaving paused ownership or replacing the task retires that scope.

The [physical Mac event monitors](../../../host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift) and [direct phone-input callback](../../../host-mac/RemoteDesktopHost/HostSession.swift) use the input-recording entry point. It records occurrence only: no key value, typed text, pointer coordinate, password or login payload is copied into this state. Non-input authorization/disconnect fences retain their existing interruption API.

While already paused, repeated input updates the in-memory generation without scheduling an actor callback, publishing a status or writing a file per event. During pending/active/approval work the same callback still closes the action gate synchronously under the injector's event-posting lock. Already-paused input does not release the person's held direct-input state. Generation exhaustion cannot wrap into an old snapshot; an exhausted scope remains unacknowledged until it is retired.

## Remote and local handback

An authenticated matching remote Pause or Resume first reconciles any unacknowledged paused input by persisting one local Pause epoch. Only the exact snapshotted generation is acknowledged after that write. Input that arrives during persistence remains unacknowledged. A delayed remote command with the old epoch receives the current paused state instead of starting execution. Replaying that command without more input does not create another local input epoch.

Resume then reserves its pending automation under an atomic comparison of the same scope/generation and the acknowledged state. Input between the checkpoint and reservation prevents admission; input after reservation revokes that exact pending claim through the preceding repair. Failed persistence keeps the marker and paused owner, leaves both versioned and legacy remote commands unacknowledged and keeps actions closed. The legacy handler now propagates that failure to transport admission instead of discarding it.

An explicit local Resume intentionally includes the person's preceding input, including the click that invokes that control. It captures the current input snapshot, persists local handback, acknowledges only that snapshot and reserves against it. Further input after that snapshot still prevents or revokes admission. Merely moving the mouse toward the local button does not change its rendered control identity and invalidate the click itself.

Stop bypasses the input checkpoint and remains absorbing. A foreign task/session cannot acknowledge another owner's marker. Legacy empty Resume cannot bypass new manual activity during a pre-prompt pause: reconciliation establishes a host epoch it has not observed, and the existing compatibility rule keeps it paused. Correct versioned control or explicit local handback remains available.

## Phone and provider behavior

The existing phone control-epoch path retires a delayed Resume when it receives the newer host epoch, persists that state before ending retry and lets the next explicit handback use the current epoch. A stale working reply with the old epoch cannot reopen the task. No new wire field or control capability is required.

The existing native provider-popup scenario now includes continued input while the child is open. The stale Resume first stops at input reconciliation. A subsequent current Resume still stops at the open-provider handback check while preserving its owner. Only after the provider callback/close and another explicit Resume does the original native goal continue against the current page. Provider close itself is neither authentication proof nor handback.

## Prepared verification

Seven new methods are authored and unrun:

- Six [host methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseTests.swift) specify interleaved snapshot/persistence/admission ordering, replacement scopes, a 1,000-event burst without ledger changes, one subsequent durable checkpoint, delayed/repeated Resume, an intentional local click, failed checkpoint persistence, legacy pre-prompt handback, foreign control, absorbing Stop and a later independent task. The gate is an internal component so its atomic boundary can be checked directly; execution control remains private to the manager.
- One [phone method](../../../ios/RemoteDesktopTests/ComputerUseClarificationClientTests.swift) specifies retirement of a delayed Resume, persistence of the new epoch, rejection of a stale working reply and a later explicit command carrying the current epoch and original task ID.

Two existing host methods are extended: readiness interruption uses the actual input-recording path, and the full native provider-popup scenario includes a paused-input checkpoint. The [focused eight-method host inventory](paused-input-ordering-inventory.json) selects these alongside the six new host methods.

Four Swift files pass parse-only checks. Source inventories select **1885 default host / 1202 focused host / 35 client core** methods. Syntax and source registration do not establish type correctness, passing assertions, native event timing, provider compatibility or model competence.

Local documentation checks cover 212 Markdown files and 1,726 local targets with no broken targets. Whitespace checks are clean, and the effective hook directory contains no executable non-sample hooks.

## Remaining sequence

1. Keep execution deferred. When authorized, compile and run the selected host/client cases, serialized transport composition and real native event monitors. Verify local pointer/keyboard gestures, held input, direct phone input, focus changes, early provider Resume and delayed deliveries on an actual Mac.
2. Qualify storage latency/failure and the complete cross-device ordering surface. The in-memory occurrence marker is scoped to a live manager; future reconstruction of native owners after process loss must not treat missing occurrence history as proof of safe handback. Native browser/account/process restoration remains incomplete.
3. Review delayed actor callbacks from active input across owner replacement and full gesture semantics. This repair creates no actor callback for input during an already-paused handoff; it does not certify every earlier asynchronous input source or device scheduling behavior.
4. Continue whole-goal/action verification, progress limits, broader question admission and conversational correction. Global navigation-source completion remains restricted pending qualification.
5. After correctness repairs, qualify supported lightweight models and total 8 GB Mac memory/thermal behavior. Coalesced bookkeeping is a source property, not a resource measurement. Alternative models and the reported RTX 3080 desktop remain in the plan; access is still unverified after the earlier SSH timeout.
6. Retain real flight, concert, movie and account-login scenarios for later explicit authorization. No live-site or local-model qualification is claimed.
