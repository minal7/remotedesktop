# Own capture preparation, native startup, callbacks and teardown

Source repair; native execution and end-to-end frame freshness remain unqualified. This implements the stream-ownership step in the [capture evidence sequence](CAPTURE_FRAME_EVIDENCE_REVIEW.md). No build, typecheck, test/assertion execution, app launch, browser/device operation, inference, SSH retry or installed-app replacement was performed.

## Findings from first principles

A frame is usable only if both its contents and its producer are authorized. Valid metadata cannot tell us whether a queued callback came from the stream that still owns the peer. A successful native start also cannot authorize a peer that was closed while the start was pending.

The previous [capture adapter](../../../host-mac/RemoteDesktopHost/ScreenCapture.swift) stored its stream only after `startCapture` returned. Two callers could both see no stream while shareable-content discovery or startup was suspended. `stop` could see nothing to stop during those awaits, after which the old task could publish an orphan stream. Callbacks did not require the current stream, and an old error could notify a replacement consumer. First-sample flags were reset from lifecycle code while callback queues read them.

The [peer](../../../host-mac/RemoteDesktopHost/HostPeerSession.swift) independently tracked `captureStarted`. A late completion could set that flag after close; old restart work could clear a successor restart task. Callback assignment and teardown were separate writes on the shared capture object. Cancellation alone did not join native work that ignored it.

## Ownership and ordering now represented in source

`CaptureStreamLifecycle` owns a peer lease, one active attempt, immutable per-owner consumer callbacks, a pending native teardown and an optional terminal cleanup failure. Preparation creates a new native stream object for every attempt. Concurrent start requests from the same owner join its existing task. Changing owner retires the previous attempt before publishing the new consumers.

| Boundary | Required ordering |
|---|---|
| Preparation | Reserve the attempt before starting asynchronous work; await predecessor teardown before discovery or native creation. |
| Native start | Install the exact prepared stream under its current attempt before calling native start, so early output can be admitted. |
| Retirement | Remove admission and cancel the attempt synchronously, then join its preparation/start task before stopping that exact stream. |
| Late preparation/start | A canceled or replaced attempt cannot publish running state. Its prepared stream, if any, remains owned by its teardown job. |
| Media | Match the exact stream and owner, validate video metadata/order, and call the synchronous consumer inside the same gate used by retirement. |
| Unexpected stop | Retire admission before notification. Deliver a one-use receipt tied to owner and attempt; replacement/start invalidates a queued receipt. |
| Cleanup failure | Retain the failure and reject replacement preparation. Failure to stop is not proof that resources were released. |

No ownership lock is held across a native await. The media gate uses a recursive lock to allow synchronous consumer-driven retirement on the same thread. A consumer must not synchronously wait for asynchronous capture start/stop. Retirement from another thread waits for an admitted synchronous consumer to return; this cannot retract work the consumer already queued in WebRTC or the audio bridge. Reentrant retirement does not preempt the body already on that thread's stack.

Video and audio now use the owner’s immutable callbacks. First-frame/audio diagnostics are keyed by attempt inside the gate. Retired video is rejected before it can advance the global host-clock order boundary. Frame order remains on the same host timeline across replacements; this change does not reset timestamps or archive pixels.

Intentional-stop callbacks and callbacks from old streams are outside admission. A current unexpected `already stopped` callback is handled as a real loss, rather than being silently ignored merely because the error code is also harmless during deliberate teardown. Native stop still treats that already-stopped result as successful cleanup. Other stop errors remain terminal for this capturer; replacement attempts fail before preparing another stream, and the restart path reports that the Mac host must be restarted. Native cleanup success/error semantics still need qualification.

## Peer integration

The peer now holds an explicit capture owner. Closing it revokes that owner and returns the lifecycle's actual teardown task. That barrier is retained on the lease, so a late close does not inherit a successor's pending cleanup; there is no growing global map of retired owners. A delayed initial start or restart cannot use a retired owner to recapture the display. The asynchronous `start` wrapper rechecks current running ownership after awaiting the shared task; no independent `captureStarted` flag can be revived by an old completion.

Restart workers have exact IDs. Only the current worker can clear its registration, and close cancels and retires it under the peer lock. A stop arriving while a successful restart is finishing cannot be lost between checking running state and retiring that worker: both decisions compose through capture admission before acquiring the peer lock. Deferred stop handling also validates and consumes its receipt in that order.

Close releases the peer lock before waiting for the capture gate. This matters because synchronous media consumers may enter native peer callbacks. Composed capture/peer transitions consistently acquire capture admission before the peer lock; native awaits occur outside both. Capture macroblock configuration and restart/ended fields now use the peer lock. This is not a general claim that all peer negotiation, channel, audio-device or signaling fields are synchronized.

## Prepared regression evidence

Twelve methods are authored and **unrun** in [ScreenCaptureSizingTests](../../../host-mac/RemoteDesktopHostTests/ScreenCaptureSizingTests.swift):

1. Concurrent starts share preparation, and output during native startup reaches the owning consumer.
2. Stop during preparation rejects late ownership, cleans its prepared stream and holds replacement preparation behind cleanup.
3. Stop during native start waits for that start before native stop or replacement, even when the fixture ignores cancellation.
4. Foreign queued frames cannot advance current frame order or deliver an old error to the successor.
5. Unexpected stop retires media before notification and supplies exactly one consumable receipt.
6. A new attempt or owner invalidates delayed stop handling.
7. A late startup failure cleans its own stream without retiring its successor.
8. Reentrant consumer retirement can install a successor without letting old close reclaim it.
9. Retirement is ordered after a synchronous media consumer returns.
10. A failed start completes native cleanup before the same owner retries.
11. A failed native stop blocks replacement preparation and preserves the underlying failure.
12. A late owner close joins its own completed teardown while the successor's native stop remains suspended.

These use fake stream objects, controlled continuations, a locked trace and a bounded semaphore wait. They do not create an `SCStream`, capture the display or exercise a codec. The source composition with real native callbacks and the peer restart worker remains unexecuted. Parse-only validation does not establish type correctness, actor/sendability correctness, assertion success or absence of native deadlock.

The [41-method stream inventory](capture-stream-host-inventory.json) preserves the preceding 29 frame/input/presentation methods and adds these twelve. Source selection matches exactly **1932 default host / 1249 focused browser-host / 41 focused stream-host** IDs. Historical frame-host remains **29**; client core and activity remain **35 / 28**. Three changed Swift files pass parse-only checks. The documentation scan checks **223 Markdown files / 1835 local targets / zero broken paths**. Whitespace validation is clean. The effective `.git/hooks` directory contains **zero executable non-sample hooks**. These are syntax and source-selection results, not executed-test results.

## Remaining repair sequence

1. **Prove media identity after recovery.** Add a scoped host capture challenge and carry its identity through the actual encoded, decoded and presented frame. The [detailed sequence](CAPTURE_FRAME_EVIDENCE_REVIEW.md#detailed-sequence-to-close-the-actual-recovery-gap) still applies; stream ownership does not prove when displayed pixels were captured.
2. **Handle stationary screens and foreground return.** Require fresh evidence before input reopens without provoking Mac input merely to generate a frame. Preserve the independently paused TLS task and explicit account-login Resume behavior.
3. **Qualify native lifecycle and composition.** With later permission, cover actual discovery/start/stop callbacks, early/late output, stop errors, startup that never returns, display changes, rapid owner churn, peer close/restart and queued codec/audio work. An indefinitely suspended native call currently keeps its teardown pending and replacement closed; cancellation is not represented as forced native termination. General peer negotiation/channel/audio-device concurrency remains a separate review item.
4. **Bound failure recovery visibly.** Nonterminal system-stop retries retain the existing backoff and remain unbounded. Define a user-visible retry budget and re-entry policy before claiming recovery readiness. Terminal cleanup failure already ends the restart worker; a safe in-process recovery from failed native cleanup is not implemented.
5. **Qualify real goals and resources later.** Run the actual travel/concert/movie and login-handback workflows only after readiness and explicit permission. Then measure the complete app on the 8 GB Mac target. Alternative models and the authorized RTX 3080 desktop remain available for measured model failures; this source repair makes no model, thermal or performance claim.
