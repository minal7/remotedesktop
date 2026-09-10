# Bound capture recovery and require output from its current stream

Source repair; native execution and remote-screen readiness remain unqualified. This continues the [stream ownership repair](CAPTURE_STREAM_OWNERSHIP_REVIEW.md) and [capture evidence sequence](CAPTURE_FRAME_EVIDENCE_REVIEW.md). No build, typecheck, test/assertion execution, app/device/browser activity, inference, SSH retry or installed-app replacement was performed.

## Findings and invariant

A restart request needs an endpoint. Returning from native startup does not establish that usable video exists, and a failed attempt must not start a new unlimited recovery budget. A timer that runs only after awaiting startup cannot bound a startup that never returns.

The previous [peer recovery loop](../../../host-mac/RemoteDesktopHost/HostPeerSession.swift) retried forever with a capped backoff. It reset recovery when the capture adapter reported a running stream, even if that stream had emitted no admitted video. A system stop during a restored-but-silent stream could repeatedly start a new worker without a shared episode budget.

A separate remaining defect was confirmed: [HostPeerInputAuthorization](../../../host-mac/RemoteDesktopHost/HostPeerSession.swift) reconciles input from the channel, hello and connection state. It has no capture-availability dimension. During an in-place capture outage, the existing direct-input session can remain authorized while the phone displays old pixels. Closing a terminal failed recovery now revokes that input, but the recovery interval still needs a coordinated host/phone repair. This change does not make that interval safe or prove input readiness.

## Source changes

`CaptureRecoveryEpisode` now supplies one monotonic deadline and attempt count. The current policy is **five startup attempts and 30 seconds per episode**, with retry waits of **250 ms, 1 s, 2 s and 5 s** after the first four failed attempts. Waits are shortened to the remaining deadline. The fifth admitted start may still produce a usable frame before the deadline; exhaustion forbids a sixth start, rather than retroactively invalidating that fifth attempt.

These are provisional product limits chosen to replace unbounded behavior, not measured native or 8 GB performance budgets. The source stores them once and derives the attempt/deadline failure messages from those values.

| State or event | Source behavior |
|---|---|
| Current system-stop receipt | Create an episode if needed; subsequent workers retain that episode's deadline and count. |
| Worker startup | Reserve one of the episode's attempts before invoking capture start. |
| Native start fails | Preserve the episode, apply its remaining retry allowance and bounded delay. |
| Native start returns without usable output | Retire that worker while keeping the episode and deadline alive; wait for source output rather than repeatedly joining the same running start task. |
| Current running attempt has admitted output | Complete the episode, cancel its deadline and retire the worker registration. |
| Another stop while awaiting output | Start another worker inside the same episode, with the remaining allowance. |
| Time or attempts exhausted | Claim terminal ownership, synchronously close input/media and report a reason that distinguishes elapsed time from attempt exhaustion. |
| Native cleanup failure | End the episode with the existing host-restart requirement; do not keep retrying a poisoned capturer. |

The deadline task sleeps independently of the worker's native await. On expiration it can begin closing the peer even when native discovery/start has not returned. The exact teardown barrier still joins that native operation; timeout is not represented as forced termination or successful cleanup. Timer scheduling and a blocked synchronous media consumer can delay close/report delivery, so this is not a measured hard wall-clock guarantee. Initial capture startup before any system-stop episode is outside this new recovery budget.

`ScreenCapture` now passes its capture-attempt lease with every validated frame, and the running-session gate supplies the current attempt's lease. The peer remembers only that identity, not a pixel archive. Early output can satisfy source recovery once that same native attempt is running. Output from a previous attempt cannot satisfy it. If output arrives after startup, the frame callback completes the existing episode under capture admission followed by the peer lock.

Clearing an awaiting worker happens under that same capture gate, so a simultaneous stop cannot be discarded merely because an old worker was still registered. Each worker keeps a separate ID from the episode: cleanup from an earlier worker cannot clear a later worker in the same episode. Deadline and terminal handlers recheck episode ownership; worker-triggered terminal actions also require the exact worker ID. A late deadline cannot end a later episode.

Source-output completion means a valid, complete, advancing frame from the currently running stream was offered to WebRTC. It does not mean encoding succeeded, that the phone received it, that it was presented, or that its display timestamp is after a negotiated recovery challenge. Those remain separate evidence requirements.

## Prepared regression evidence

Seven methods are authored and **unrun** in [ScreenCaptureSizingTests](../../../host-mac/RemoteDesktopHostTests/ScreenCaptureSizingTests.swift):

1. Preserve episode identity/deadline through five attempts and prohibit a sixth.
2. Reject startup and source completion at and after the exact deadline, including an outage with only one attempted start.
3. Clip retry delay to the remaining deadline without extending it.
4. Require admitted output from the current running attempt instead of native startup or an older attempt's output.
5. Allow the fifth attempt to produce a frame while disallowing another start.
6. Keep a new episode's identity, deadline and count separate from its predecessor.
7. Compose the real stream-lifecycle gate with fake native starts: early output matches once running, then fails to match a replacement stream.

Six methods use supplied monotonic instants without sleeping. The seventh uses a controlled fake stream/latch and no native display capture. These do not execute the real peer's watchdog, restart-worker races, transport shutdown or frame delivery. The native cases still need permission and an executable toolchain.

The [48-method recovery inventory](capture-recovery-host-inventory.json) preserves the preceding 41 capture/input/presentation methods and adds these seven. Source selection matches exactly **1939 default host / 1256 focused browser-host / 48 focused recovery-host** IDs. Historical stream-host remains **41**; client core/activity remain **35/28**. Three changed Swift files pass parse-only checks. The documentation scan checks **224 Markdown files / 1845 local targets / zero broken paths**. Whitespace validation is clean. The effective `.git/hooks` directory contains **zero executable non-sample hooks**. None of this is assertion or compilation evidence.

## Remaining recovery/input work

1. **Retire input at capture loss.** Add capture availability independently of ICE/channel connectivity. Release the current injector session and its held inputs when capture is lost. Neither a duplicate hello nor a connection callback may reopen it while capture is unavailable.
2. **Notify the owning phone scope.** Send a scoped input-unavailable event and clear the phone's old hello/display/frame readiness and source generations. An old event must not invalidate a new acknowledgement. Preserve the independent TLS prompt and paused login task.
3. **Recover through a new scope.** Rotate input identity and reject packets buffered before the outage. Handle both event/hello orders, early callbacks, notification failure, unknown messages and legacy clients explicitly. Input without freshness identifiers cannot simply resume the old channel.
4. **Prove capture-to-presentation identity.** Carry a current host-clock challenge through encoded media, decoding and the owning renderer; direct timestamp equality is already known to be insufficient. The [detailed frame-proof sequence](CAPTURE_FRAME_EVIDENCE_REVIEW.md#detailed-sequence-to-close-the-actual-recovery-gap) remains open.
5. **Handle static screens, foreground return and repeated failures.** A stationary screen must have a bounded evidence path. Source-output recovery can currently create a new episode if another stop follows a valid frame; define a connection-level repeated-failure policy and tie remote readiness to actual presentation. Initial startup, negotiation/channel/audio-device concurrency and in-process recovery from native cleanup failure remain open.
6. **Qualify real behavior later.** Exercise native startup that hangs, late frames, deadline/close races, transport notifications and independent login Resume. Then, with explicit permission, run actual travel/concert/movie tasks and verify results against their sites. Measure resource use on the 8 GB target only after correctness work; no model or fan-load claim follows from these source changes.
