# Native presentation surface integration

Source integration, 2026-09-10. This follows [frame preparation](FRAME_IMAGE_PREPARATION_REVIEW.md) and [candidate visibility](CANDIDATE_SCREEN_VISIBILITY_REVIEW.md). The iOS client source now instantiates the Core Image/Metal producer for the Mac screen and uses its attachment's presentation channel for WebRTC readiness. The installed app was not replaced. No builds, typechecks, assertions, app launches, native rendering, computer-use actions or model inference ran. This is an unqualified implementation change, not proof of working native presentation or natural-language tasks.

## First-principles chain

The old synchronous forwarding callback proved only that a sink accepted a decoded frame. Input must not treat that callback as a displayed image. The new source chain is:

1. Retain the latest decoded frame under the current local surface context.
2. Acquire one bounded drawable without blocking the main thread.
3. Take the newest waiting frame and encode it into that exact drawable.
4. Join successful GPU completion and positive presentation time for that drawable.
5. Check the current native surface, layout context, transport track and input lease.
6. Report local presentation readiness; withdraw it on context loss or failure.

This chain still does not prove host capture time, pixel fidelity or absence of an occluding window. The distinction is part of the contract, rather than an inference from a method named “first frame.”

## Surface, queue and ownership

[RemoteVideoPresentationSurface](../../../ios/RemoteDesktop/Transport/RemoteVideoPresentationSurface.swift) owns a fresh Metal view, producer and presentation channel for one native attachment. Its nonisolated WebRTC methods do not read UIKit. `setSize` no longer interprets decoded pixels as UIKit points; decoded geometry comes from the retained frame, and drawable dimensions come from the owned view.

[RemoteVideoLatestFrameMailbox](../../../ios/RemoteDesktop/Transport/RemoteVideoLatestFrameMailbox.swift) has one unsubmitted frame slot and one outstanding wake per context. New arrivals replace the waiting frame rather than creating a task/queue entry for every image. Replaced frames are released outside the lock. A take returns the latest frame, and a retry of an uncommitted admission can restore it only when no newer frame is waiting. Context retirement drops the frame and invalidates old wakes/restores. The source buffer must remain immutable while retained; that native decoder contract still needs qualification.

Drawable acquisition uses one process-wide worker slot with no queued backlog. The worker sets the requested bounded drawable size and calls `nextDrawable`; it does not read UIKit or retain decoded frames. Apple's [drawable API](https://developer.apple.com/documentation/quartzcore/cametallayer/nextdrawable()) and the inspected SDK describe waiting when the swap queue is exhausted. The layer explicitly enables its [native timeout](https://developer.apple.com/documentation/quartzcore/cametallayer/allowsnextdrawabletimeout), and its [drawable count](https://developer.apple.com/documentation/quartzcore/cametallayer/maximumdrawablecount) is set to two. Retirement discards the returned drawable using the request/context identity; it does not pretend to cancel the native call or free the occupied worker slot before return.

Each active surface admits one frame at a time, while the existing shared ledger retains at most two GPU reservations across current and retired contexts. The drawable is obtained before taking the waiting frame, so a slow acquisition does not pin an obsolete decoded frame ahead of newer arrivals. Encoding remains on MainActor. The I420 preparation path and its explicit SDR interpretation are unchanged from the previous checkpoint.

The layout context contains the native window identity, view rectangle in that window, visible viewport, bounded physical drawable size and fill/aspect-fit mode. View/window layout callbacks and explicit viewport updates from pan/zoom re-evaluate it. A changed context closes presentation readiness, drops the waiting frame, cancels old observers/retries and retires the producer's old context. Privacy/activity detachment still uses the preceding cleanup ordering and creates a different native layer for the replacement attachment.

The source removes `MetalSafeRTCVideoView` and its now-unused point-size workaround. Three existing sizing/geometry cases now exercise physical drawable sizing, including logical input/video alignment independently of integer drawable rounding. Destination limits are 8192 pixels per dimension and 16,777,216 pixels in total; these are allocation preflights, not measured 8 GB or thermal budgets.

## Readiness and failure handling

[RemoteVideoSurfacePresentation](../../../ios/RemoteDesktop/Transport/RemoteVideoSurfacePresentation.swift) carries waiting, presented, failed and retired state. Events retain the context, decoded frame identity and presentation time. Old contexts, invalid/regressive times and publication after terminal failure/retirement are rejected. State commits before observer delivery, so a nested replacement cannot be overwritten by the previous publication.

[RemoteVideoSurfaceAttachment](../../../ios/RemoteDesktop/Transport/RemoteVideoSurface.swift) carries this channel and silences it before native cleanup. The lifetime rechecks its reservation after obtaining the channel as well as after factory/install callbacks. A native WebRTC attachment without a channel, or with an already retired channel, is a preparation failure; it cannot fall back to forwarding-based readiness. Existing non-video recording fixtures may omit the channel because they explicitly synthesize their own transport events.

[WebRTCTransport](../../../ios/RemoteDesktop/Transport/WebRTCTransport.swift) installs the observer under the exact current track, attachment, renderer lease and input handshake. It checks that the received event is still the channel's current state. Only the first presented event after a waiting interval raises readiness. Waiting withdraws readiness and invokes the existing owned-input cleanup; failure closes that video transport. The optional visual sidecar remains independent of the TLS AI task. The forwarding subscription still joins native sink calls on retirement, but its forwarding callback is no longer an input authority.

Unavailable drawables, a busy shared slot, allocation/locking failure and encoding failure use bounded retries. An uncommitted frame can be retried unless replaced; a committed frame/drawable is never resubmitted. Skipped or failed presentation waits for a newer decoded frame. Unsupported formats and expired presentation terminate the affected screen. The provisional policy uses a 100 ms retry delay, at most 30 failed attempts, and a five-second observation/recovery deadline. Deadline/retry identities prevent cancelled callbacks from mutating a replacement. An unfinished GPU operation continues occupying its ledger slot until actual completion.

## Prepared checks

Nine methods in [RemoteVideoPresentationSurfaceTests](../../../ios/RemoteDesktopTests/RemoteVideoPresentationSurfaceTests.swift) are authored and **unrun**. They specify latest-frame retention and wake coalescing, context retirement, uncommitted restoration, concurrent offers, presentation context/time rejection, terminal failure, nested publication, physical drawable sizing and channel retirement before native cleanup. These supporting cases do not construct a producer, allocate a drawable, exercise the worker/timers, receive actual WebRTC frames or establish the transport's native callback ordering.

Three existing methods in [RemoteScreenInteractionTests](../../../ios/RemoteDesktopTests/RemoteScreenInteractionTests.swift) retain their sizing/alignment purpose using the active sizing implementation. The [surface inventory](presentation-surface-client-inventory.json) preserves 81 committed frame-image identifiers and adds the nine new methods plus two previously unselected sizing methods. [Client core](../../../ios/AcceptanceFixtures/computer-use-client-core-tests.json) preserves 128 committed identifiers and adds the same eleven selections. Expected names came from HEAD plus the reviewed explicit lists, independently of source discovery. The existing XcodeGen source directories include the new files; the ignored generated project was not regenerated.

Eleven Swift files pass parse-only checks. Nine inventories match selected source identifiers: **2025 default host / 1342 focused browser host / 139 client core / 92 presentation surface / 81 frame image / 74 presentation producer / 26 candidate visibility / 110 pause acknowledgement / 65 native surface**. Documentation checking covers **253 Markdown files / 2154 local targets / zero missing paths**, with anchors unchecked. Whitespace validation is clean. The effective `.git/hooks` directory contains **zero executable non-sample hooks**. These checks establish source consistency, not compilation or passed runtime assertions.

## Remaining correctness and qualification gates

- **Native behavior is unproven.** Swift/Objective-C import and actor compatibility need compilation; real layer sizing, background drawable acquisition, command submission, callback order, skipped presentation, timeout, teardown and transport readiness need controlled execution. Supporting state/byte fixtures cannot prove that pixels are visible or correct.
- **Source freshness remains separate.** A frame admitted after a local context change may contain an older host capture or queued decode. No capture timestamp or source generation was fabricated here. Review stationary-screen and viewport/reveal recovery next: this implementation waits for a newly delivered decoded frame after context replacement, and a source that emits none will reach its bounded failure. It does not yet establish a fresh-image demand path for every such transition.
- **Occlusion and color remain open.** Explicit layout/viewport/window/privacy updates are handled; arbitrary ancestor changes, native occlusion and delayed compositing require evidence. I420 uses the declared SDR compatibility default, and exact chroma/color/crop/rotation output is unqualified. The same producer command queue spans local context changes; actual retired/current drawable ordering must be observed, not inferred from suppressed callbacks alone.
- **Bounds do not prove responsiveness.** Core Image preparation/encoding still runs on MainActor, so a native call there can delay timer delivery. The worker timeout and two GPU slots are not cancellation or memory-reclamation proofs. Decoder, staging, Core Image, drawable and retained native resources need measurements, including non-returning callbacks and the 8 GB/fan target.
- **Product acceptance remains open.** Real account login/handback, pause quiescence, full travel/concert/movie tasks and local-model natural-language behavior still require later explicit execution permission. No model was changed, run or trained, and no desktop SSH connection was retried here.
