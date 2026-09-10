# Bind phone coordinates and layout to the native captured display

Source repair; compilation, native geometry and end-to-end presentation remain unverified. This implements the display identity/origin portion of the [fresh-image design](CAPTURE_FRESH_IMAGE_DESIGN_REVIEW.md), while retaining [bounded startup](CAPTURE_STARTUP_REVIEW.md), [capture loss](CAPTURE_AVAILABILITY_REVIEW.md) and [input scope invalidation](CAPTURE_INPUT_INVALIDATION_REVIEW.md). No build, typecheck, test/assertion execution, app/device/browser operation, native capture, inference run or SSH retry was performed.

## Problem and resulting behavior

Capture selected a CoreGraphics display, while each hello/layout response independently read AppKit's key-window screen. Those sources can identify different monitors. The phone derives its coordinates from the advertised dimensions, but the injector posted them directly as global coordinates. A captured fallback display with a nonzero origin could therefore receive input at the wrong global position. Scroll events also discarded their supplied location.

The source now retains one display descriptor with each native capture attempt. That descriptor supplies the phone's logical width/height/backing scale and the transform applied to its pointer/scroll positions. Focusing a window on another monitor no longer changes layout publication. For example, a captured display at global origin `(-1600, 120)` maps phone position `(100, 200)` to global position `(-1500, 320)`.

This closes the independent-screen selection and missing-origin paths in source. It does not establish that every encoded/rendered content rectangle is mapped correctly; that separate requirement remains open below.

## Native descriptor and ownership

[CaptureDisplayState](../../../host-mac/RemoteDesktopHost/ScreenCapture.swift) records the selected display ID, global logical bounds, mode pixel dimensions and rotation. Native sampling reads that exact display's online state, bounds and mode through CoreGraphics. It never chooses a display through the key window. The installed SDK declarations for online state, mode pixel dimensions and rotation were inspected.

`CaptureDisplayGeometry` validates integer-representable positive logical sizes, bounded native numeric representation, supported right-angle rotation and backing scale. The full-display filter's content size must match the selected native logical size. Invalid, fractional, nonfinite or inconsistent dimensions cannot reach the prior unchecked backing-size integer conversion. The descriptor includes a unique identity even when a later attempt has identical geometry.

The native lifecycle resource now bundles SCStream, its filter, configuration and descriptor. The generic lifecycle can return the exact running resource. A separate native-stream lookup returns only a reference: output/error callbacks still pass through exact object/owner admission before using it. A late lookup cannot borrow a replacement's context. The retained filter/configuration is preparation for an owned fresh-image request; no screenshot request is introduced here.

Current video callbacks and running-session checks compare the descriptor with a fresh native state sample. A detected change retires the exact stream, revokes input through its synchronous stop callback and enters the existing bounded restart episode. Initial discovery, restart budgets, one-use stop receipts and real native cleanup barriers remain in force. Complete buffers must also match the configured output width/height before admission.

## Input and publication

[HostPeerInputAuthorization](../../../host-mac/RemoteDesktopHost/HostPeerSession.swift) requires a capture descriptor by default. Merely setting capture available, or passing an initial-available flag, cannot authorize production input without one. Existing handshake-only fixtures explicitly disable that requirement. A local injector session retains the immutable descriptor, and the production [layout encoder](../../../host-mac/RemoteDesktopHost/WireFormat.swift) accepts that same descriptor.

Normal descriptor replacement follows capture unavailable → held-input release/scoped invalidation → new available capture → new input generation. Trying to replace geometry while the old capture scope is still available closes the authority and requires reconnect. An old input stamp or local token cannot be remapped onto a replacement descriptor.

[InputInjector](../../../host-mac/RemoteDesktopHost/InputInjector.swift) checks the selected native display before the intervention callback and again at posting. Text rechecks it between complete graphemes. Screen-local positions outside the advertised logical bounds are rejected before interrupting automation. Valid pointer and scroll positions receive the descriptor's global origin; key/text semantics and AI/global-desktop input coordinates retain their existing meaning. Scroll now sets the translated location on its CGEvent without changing its deltas.

When native layout differs at posting, the injector permanently retires that exact local session and releases its held input at previously recorded global coordinates. It records one pending descriptor-invalidation receipt. The peer consumes that receipt outside the posting lock and retires only a running capture with the same descriptor identity. A rapid return to old bounds cannot erase an already observed loss, and a replacement native descriptor with identical dimensions cannot be retired by that old receipt. New input sessions cannot consume another session's receipt. The slot is bounded; a later observed loss supersedes an earlier unconsumed observation.

Native geometry sampling does not acquire peer/capture locks inside the injector. Capture teardown is requested only after posting returns, preserving the existing lock order. Already posted events cannot be retracted, and native display reconfiguration itself is not locked by this app's posting lock.

The [wire contract](../../../protocol/PROTOCOL.md#pointer-client--host) now explicitly describes captured-display logical coordinates and host-side origin mapping. Width/height/scale and input-scope fields keep their existing encoding; no new client payload or capability is added. The current phone already derives screen-local positions from those dimensions. Earlier hosts do not gain this repair, and compatibility remains unqualified.

## Prepared regression evidence

Nine methods are authored and **unrun** across [ScreenCaptureSizingTests](../../../host-mac/RemoteDesktopHostTests/ScreenCaptureSizingTests.swift) and [ComputerUseTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseTests.swift).

Four geometry/lifecycle cases cover invalid or inconsistent dimensions, exact global corner/scroll mapping including a rotated display's logical bounds, rejection of ID/bounds/mode/rotation/offline changes, and inability of a retained lookup or old owner to admit a replacement resource. Five authority/injector cases cover the production descriptor requirement and real layout encoder, posted pointer/scroll locations, loss between admission and posting, old held-coordinate cleanup, one-use loss receipts, per-grapheme retirement, protection of replacement holds, and explicit invalidation before a new display scope.

Fixtures supply fake display-state providers and captured CGEvent posters; they do not query the user's displays or post events to the desktop. The lifecycle fixture uses fake stream objects. Actual NativeStream/SCStream callbacks, renderer padding, display-event ordering and provider hit testing are not executed by these fixtures. Existing handshake-focused cases explicitly retain their earlier unbound-fixture mode.

The [display inventory](capture-display-host-inventory.json) retains the prior 67 capture/input/startup identifiers and adds the nine named cases. Source inventories select **1967 default host / 1284 focused browser-host / 76 focused display host** methods. Unchanged capture-input client and client-core inventories retain **32 / 35** methods. Expected identifiers were extended from the prior committed inventories with the nine explicit names.

Six changed Swift files pass parse-only checks. The documentation scan checks **229 Markdown files / 1910 local targets / zero broken paths**. Whitespace validation is clean, and the effective `.git/hooks` directory contains **zero executable non-sample hooks**. These are syntax and source-selection checks, not compilation, passing assertions, native coordinate qualification or resource measurements.

## Remaining repair sequence

1. **Bind actual content placement.** The full-display descriptor does not yet carry a verified per-frame content rectangle through encoding and rendering. Encoder scaling/even sizing, letterboxing, Presenter Overlay, track adaptation and the phone's aspect-fit rectangle need one validated transform. Do not infer that configured dimensions alone prove full-surface content.
2. **Qualify display changes between samples.** The subsequent [display-change repair](CAPTURE_DISPLAY_CHANGE_REVIEW.md) adds a native notification token, bracketed sampling/preparation and queued exact-stream retirement. A reported change and return cannot reuse the old token. Callback delay, missing notifications and changes concurrent with an already admitted native event still need qualification. Mode/rotation sampling and the full-display content-size assumption also remain unverified.
3. **Implement the bounded fresh-image request.** The exact filter/configuration/descriptor is now retained. Add the request lease and real-operation capacity rules from the [fresh-image sequence](CAPTURE_FRESH_IMAGE_DESIGN_REVIEW.md#implementation-order-and-acceptance-requirements). Screenshot metadata freshness and continuing-stream availability remain distinct, unqualified requirements.
4. **Prove presented and foreground recovery.** Carry source identity through the actual codec and renderer, reject old queued images/layouts and rearm evidence when the phone becomes active. A layout message and an independent decoded-frame probe do not prove correct current pixels.
5. **Qualify user workflows later.** After explicit permission, exercise primary/fallback displays, focus changes, hotplug/rearrangement, scaling/rotation, scroll hit testing, holds and recovery, then exact paused-login preservation and real travel/concert/movie tasks. Native geometry-query cost and the 8 GB model/resource target remain later measured work.
