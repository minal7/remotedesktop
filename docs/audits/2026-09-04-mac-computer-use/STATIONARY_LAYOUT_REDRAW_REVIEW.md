# Stationary images across local layout changes

Source repair, 2026-09-10, following the [native presentation integration](PRESENTATION_SURFACE_INTEGRATION_REVIEW.md). Continuous zoom, pan or resizing in the same native window now retains the latest decoded image for a new drawable. This is local redraw, not a fresh capture request. The installed app was not replaced. No compilation, typechecking, assertions, app launch, native capture/rendering, computer-use action, inference or SSH retry ran.

## First-principles distinction

An unchanged Mac desktop is a valid image. [ScreenCapture](../../../host-mac/RemoteDesktopHost/ScreenCapture.swift) treats `idle` as no display change and does not forward it as a new complete image. [HostPeerSession](../../../host-mac/RemoteDesktopHost/HostPeerSession.swift) restores capture input only from the current running attempt's accepted complete output. Starting a stream, receiving an idle event, or displaying cached pixels cannot substitute for that source evidence.

The previous client driver discarded its waiting image on every layout context change and retained no image after submission. A stationary source could therefore supply nothing for a resized viewport, and the client would reach its five-second failure. Local geometry and source loss had been coupled to the same requirement for another decode.

The repaired source distinguishes these transitions:

| Transition | Retained image | Readiness requirement |
| --- | --- | --- |
| Eligible layout changes continuously in the same native window | Latest image may move into the new local context, with its original decode ID | Successful GPU completion and presentation of a new drawable in that context |
| Newer decoded image arrives before acquisition completes | Replaces the retained candidate | Receipt for the selected image and current drawable |
| Hidden, windowless, ineligible or changed-window surface | Discarded | New admitted decode and current presentation; source freshness remains unproved |
| Privacy/activity, track, input-scope or attachment replacement | Old attachment is retired; replacement owns another mailbox | Existing replacement handshake/attachment gates, then presentation |
| Current failed/skipped presentation | Matching retained image is discarded; a newer decode survives | A newer candidate must present successfully |
| Host blank/suspended/stopped capture | Existing host invalidation remains authoritative | Current source recovery and the client input/presentation gates |

## Image lifetime and identity

[RemoteVideoLatestFrameMailbox](../../../ios/RemoteDesktop/Transport/RemoteVideoLatestFrameMailbox.swift) keeps one latest image and a separate pending-work flag. Taking a frame consumes the pending request while retaining the image. A successful stationary presentation therefore does not cause a render loop. Another render needs a new decode, an eligible layout transition or an explicit uncommitted retry.

Layout transfer requires the exact previous context and a non-nil replacement. It changes the local context while preserving the decoded frame's ID and object. The caller immediately requests work under the new context; obsolete queued wakes and restores cannot consume that work. A later decode replaces the transferred candidate before the drawable is used. Ordinary context replacement still discards the image.

An uncommitted restore must match the latest image's ID. Previously, an older restore could succeed after a newer image had already been taken, because an empty pending slot was treated as permission to restore. Keeping latest identity separately prevents that regression. Discarding a failed current image also prevents a later restore from resurrecting it.

Replaced or discarded images are released after the mailbox lock is unlocked. The one-image retention bound does not grow with layout changes. Native GPU work keeps its existing shared two-slot accounting and resource lifetime; a retained mailbox reference may share the image already owned by that work. This is an ownership bound, not an 8 GB or thermal measurement. Decoder buffers must remain immutable while retained; actual native behavior is still unqualified.

## Surface and recovery ordering

[RemoteVideoPresentationSurface](../../../ios/RemoteDesktop/Transport/RemoteVideoPresentationSurface.swift) permits transfer only between two eligible layouts in the same live `UIWindow`. A weak window reference checks actual object identity without retaining the window or treating a reused numeric object address as continuity. A nil layout, lost window, changed window, failure or retirement discards the image.

Every layout change still retires the old producer context and withdraws readiness. A redraw submits the retained image through a new drawable, command and presentation ticket; no old drawable, command or receipt is reused. The original decode ID remains visible in the receipt. No host capture time or generation is manufactured. Old context callbacks cannot reopen the new context.

A current failure is processed **before** re-reading layout: failed/skipped output discards its matching candidate first, and expiration terminates immediately. Otherwise a geometry change discovered in the callback could transfer the failed image and turn its failure into an ignored old-context event. A failure belonging to an already retired context still cannot mutate its successor.

Continuous layout changes preserve the existing retry task, attempt count and recovery deadline. A pending retry resumes work for the current context, and the original deadline fails the current context if the episode still owns it. Layout notifications cannot bypass a pending retry or renew the five-second budget. Successful current presentation cancels the episode; visibility/window boundaries and retirement cancel its identities. Retry/deadline instants are captured before scheduling their tasks, so delayed task startup does not add another full interval. MainActor blocking can still delay delivery and is not solved by a timer.

## Prepared checks and source verification

Seven methods were added to [RemoteVideoPresentationSurfaceTests](../../../ios/RemoteDesktopTests/RemoteVideoPresentationSurfaceTests.swift), all **unrun**. They specify retained decode identity without repeated work, pending-frame transfer and wake retirement, visibility/attachment boundaries, exact predecessor requirements, failed-image discard while preserving newer output, rejection of a late older restore after a newer take, and reentrant release outside the mailbox gate. They use supporting frame objects, not WebRTC/native rendering execution. They do not exercise the surface's UIKit callbacks, timers or actual transport behavior.

Expected names were added explicitly to the committed [client core](../../../ios/AcceptanceFixtures/computer-use-client-core-tests.json) and [surface](presentation-surface-client-inventory.json) manifests, preserving prior selections. Three changed Swift files pass parse-only checks. Nine inventories match selected source identifiers: **2025 default host / 1342 focused browser host / 146 client core / 99 presentation surface / 81 frame image / 74 presentation producer / 26 candidate visibility / 110 pause acknowledgement / 65 native surface**. These are source consistency checks, not passed runtime tests.

Documentation checking covers **254 Markdown files / 2169 local targets / zero missing paths**, with anchors unchecked. Whitespace validation is clean. The effective `.git/hooks` directory contains **zero executable non-sample hooks**. No test methods or native APIs were executed by these checks.

## Remaining repair sequence

1. Complete a separately scoped fresh-image request for reveal and source recovery. Retain exact capture owner, native attempt, display descriptor, recovery episode, request identity and an actual acquisition boundary. The [fresh capture design](CAPTURE_FRESH_IMAGE_DESIGN_REVIEW.md) still applies; a native still callback cannot be relabeled as a current capture timestamp or proof that the ongoing stream recovered.
2. Carry and validate source identity through the actual media path. The [frame evidence review](CAPTURE_FRAME_EVIDENCE_REVIEW.md) explains why decoded WebRTC timestamps or a data-channel acknowledgement alone are insufficient. This repair adds no wire claim of source freshness.
3. With later explicit permission, compile and exercise native presentation across stationary zoom/resize, failures during layout, hide/reveal, window replacement, queued old GPU work, capture interruption, and input cleanup. Verify actual pixels/order, task ownership and cancellation, not only helper states.
4. Qualify source color/crop/rotation, account login and handback, then complete travel/concert/movie natural-language tasks using measured local models. Resource qualification for 8 GB Macs and the fan issue remains a later phase. Alternate models and the authorized RTX 3080 desktop remain options; no model change or desktop run is part of this checkpoint.
