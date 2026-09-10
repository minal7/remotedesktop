# Withdraw input when capture output becomes unavailable

Source repair; native execution and remote presentation qualification remain pending. This extends [capture-stop input invalidation](CAPTURE_INPUT_INVALIDATION_REVIEW.md), [bounded recovery](CAPTURE_RECOVERY_BUDGET_REVIEW.md) and [source-frame validation](CAPTURE_FRAME_EVIDENCE_REVIEW.md). No build, typecheck, test/assertion execution, app/device/browser operation, inference run, SSH retry or installed-app replacement was performed.

## First-principles findings

A live stream object is not evidence of a usable image. A stream can remain open while output is blank or suspended. Conversely, an unchanged display is not a capture failure. The previous complete-only filter silently discarded all these statuses, leaving the last source frame and input authorization in place until an explicit stream-stop delegate callback arrived.

The installed [ScreenCaptureKit SDK header](</Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/ScreenCaptureKit.framework/Headers/SCStream.h:41>) distinguishes complete, idle, blank, suspended, started and stopped statuses. Idle reports no display change; blank and suspended report unavailable updates. That distinction supports explicit handling of reported loss. It does not promise a callback cadence or prove that a period without callbacks is a failure.

A second issue appears when the same stream resumes: its identity has not changed. A cached last-frame identity can still equal the running stream after loss. Restoring input must check current output availability under the stream admission gate, as well as checking ownership and the recovery deadline.

## Implemented source behavior

[ScreenCapture](../../../host-mac/RemoteDesktopHost/ScreenCapture.swift) now decodes status independently of image readiness and display-clock metadata. Booleans, strings, fractional values, unknown statuses and invalid/missing attachments are rejected. A status-only event does not require ready pixels. Complete output still requires the existing validated image buffer and host-clock metadata.

| Reported condition | Source behavior |
| --- | --- |
| Idle | Preserve prior availability; do not restore unavailable output. |
| Blank or suspended | Withdraw output and notify the peer synchronously. |
| Invalid status or unusable complete sample | Withdraw output through the same path. |
| Started before any delivered frame in the attempt | Retain closed startup state; await complete output. |
| Started after established output | Withdraw the previous image and await new complete output. |
| Stopped | Retire the stream and issue the existing one-use stop receipt, with a typed recoverable reason. |
| Valid advancing complete frame after the loss boundary | Admit the frame and permit source recovery for its exact running attempt. |

The complete-only startup policy remains in place. This change does not establish that all native started samples lack usable pixels; the actual startup/static-screen sequence still needs qualification.

Availability records the host monotonic clock when loss is observed. A complete frame whose WindowServer display time is at or before that boundary cannot restore output. Repeated loss advances the boundary conservatively, but publishes only the first unavailable notification until another frame is admitted. The boundary never regresses and survives native stream/owner replacement. A new stream identity cannot make an older image fresh. Foreign callbacks remain excluded by the existing lifecycle gate before they can alter these records.

The availability check precedes frame-order admission, so a rejected candidate does not advance the accepted frame timeline. Delivery records and running-session availability are read or changed inside the same capture gate, including native delegate stops. An idle event does not change these records.

[HostPeerSession](../../../host-mac/RemoteDesktopHost/HostPeerSession.swift) clears its remembered frame identity and revokes capture input synchronously when output becomes unavailable. This reuses the negotiated phone invalidation, held-input release and legacy reconnect behavior from the preceding repair. It then starts the existing 30-second recovery episode for the continuing stream. The native stream is left running; blank/suspended callbacks do not create restart loops.

Same-stream recovery needs no reserved native startup attempt. The episode records which continuing attempt is eligible; a different attempt cannot use that exception. If the stream subsequently stops, native restart uses the same episode, original deadline and five-attempt budget. Existing episodes are retained, including when a replacement stream reports unavailable output during startup. Only actual admitted output from an available running attempt before the deadline can finish recovery. Startup completion and cached frame identity cannot independently reopen input.

Both the sample-level stopped status and the native stop delegate retire the current stream before asynchronous recovery. A later duplicate callback from that retired stream cannot issue another receipt. Only the typed output-stop reason or the existing system-stop error uses recoverable restart; other errors keep the terminal path.

## Prepared regression evidence

Nine methods are authored and **unrun** in [ScreenCaptureSizingTests](../../../host-mac/RemoteDesktopHostTests/ScreenCaptureSizingTests.swift). They cover strict status decoding, status-only samples without ready pixels/display time, initial versus established started markers, queued frames before/at the loss boundary, notification deduplication and nonregressing clocks, replacement identity, continuing-stream recovery with an unchanged deadline, recoverable error classification, and a running fake stream whose cached identity remains unchanged while source availability is false.

The composition fixture uses the generic fake lifecycle and source availability state. It does not execute HostPeerSession, native SCStream, a peer connection or a renderer. Parser/value-state fixtures do not establish native status ordering, missing-image attachment shapes or provider behavior.

The [availability inventory](capture-availability-host-inventory.json) retains all 55 prior capture/input host methods and adds the nine named methods. Default host and focused browser-host inventories retain all earlier expected identifiers. Source inventories select **1955 default host / 1272 focused browser-host / 64 focused availability host** methods. The unchanged capture-input client and client-core inventories select **32 / 35** methods.

Three changed Swift files pass parse-only checks. The documentation scan checks **226 Markdown files / 1872 local targets / zero broken paths**. Whitespace validation is clean. The effective `.git/hooks` directory contains **zero executable non-sample hooks**. These are syntax and source-inventory checks; they do not execute assertions or establish compilation, native behavior, natural-language correctness or acceptable resource use.

## Remaining repair sequence

1. **Obtain a bounded fresh image for static recovery.** Callback-time loss observation is deliberately conservative: a valid resume frame may have been captured before that observation. If the display then stays unchanged, this patch can remain unavailable until the original deadline. Design a fresh-capture request bound to the current owner and host-clock challenge; do not move/click the user's desktop to provoke a change. Qualify native started and idle behavior rather than assuming callbacks repeat.
2. **Handle unreported loss and initial startup.** The subsequent [startup repair](CAPTURE_STARTUP_REVIEW.md) includes initial capture in the existing deadline/attempt budget and frees signaling from the capture await. Silent stalls, blocked consumers and permission/display changes with no loss status still require an explicit observation/probe policy and connection-level repeated-failure limits. The current timer cannot force a hung native call to terminate, and synchronous consumer blockage can delay downstream closure. Native startup qualification remains pending.
3. **Bind readiness to actual presented media.** Source availability is only one prerequisite. Carry the current challenge and frame identity through encoding, transport, decoding and the owning renderer. A data-channel notification or an independent decoded-frame probe is not capture-to-presentation proof. Follow the [media evidence sequence](CAPTURE_FRAME_EVIDENCE_REVIEW.md#detailed-sequence-to-close-the-actual-recovery-gap).
4. **Rearm foreground recovery.** Phone activity currently has its own input gate but still needs fresh presentation evidence after returning active. Keep source leases, display scope and renderer ownership aligned across these transitions.
5. **Qualify native recovery and login later.** Check idle/blank/suspended/started/stopped sequences, held input, message ordering, startup/close races, actual rendering, compatibility and preservation of the exact paused login/TLS task. Require deliberate Resume and fresh native page evidence. Real travel/concert/movie workflows remain deferred until explicit permission. Model selection, the authorized remote GPU option, thermal behavior and the 8 GB target remain later measured work.
