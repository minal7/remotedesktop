# Retire capture and direct input across reported display changes

Source repair; native notification delivery, compilation and end-to-end behavior remain unverified. This extends the [display-binding repair](CAPTURE_DISPLAY_BINDING_REVIEW.md) with configuration history. No build, typecheck, test/assertion execution, native registration/capture, app/device/browser operation, model run or SSH retry was performed.

## Problem and resulting behavior

Comparing current display dimensions with saved dimensions loses history. A display can change and return to the same ID, origin, size, pixel mode and rotation between all samples. The old descriptor would then match, although capture and input had crossed a configuration change.

[ScreenCapture](../../../host-mac/RemoteDesktopHost/ScreenCapture.swift) now assigns a new process-local token to every reported native display-reconfiguration callback. Native display snapshots retain that token. Old descriptors cannot match a later token even when all numeric properties are equal. This changes direct-input admission through the existing descriptor checks in [InputInjector](../../../host-mac/RemoteDesktopHost/InputInjector.swift), including the second check before posting and checks between complete text graphemes.

The token is not a timestamp, capture-frame identity or proof that the operating system has delivered every event. It records the notifications actually observed by this process.

## Native contract and lifetime

The installed [CoreGraphics callback contract](</Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/CoreGraphics.framework/Headers/CGDisplayConfiguration.h:187>) documents a begin callback for each online display before configuration, and post-change callbacks for added, removed and currently online displays. CoreGraphics display state is current when the post-change callback is invoked. Callbacks run on the event-processing thread, or inside the configuring application's reconfiguration function. This supports notification-based invalidation; it does not provide an application lock around OS configuration and input posting.

One process-lifetime monitor registers the C callback and retains its context. Each capturer owns a removable subscription whose closure refers weakly to the capturer. Deinitializing a capturer removes that subscription. The single native registration intentionally remains alive for the process, avoiding a dangling callback context during concurrent removal/delivery. Registration failure leaves native display admission unavailable. Ordinary host-session fixtures skip capturer subscriptions; explicitly invoking native display reads still requires the real monitor.

The native callback performs two bounded operations: update the locked configuration fence, then arrange coalesced observer delivery on a serial queue. It never invokes capture teardown, peer callbacks or input cleanup directly. Listener callbacks run outside the monitor's registry lock. There is at most one queued delivery in addition to one running delivery; each delivery rereads current state, so it does not need an unbounded event history.

The fence retains a set of display IDs with unmatched begin notifications. No stable token is available until that set drains. Repeated begins for the same ID do not add entries. A post-change notification without a seen begin still rotates the token. A null ID or more than 64 simultaneously pending IDs leaves the fence unavailable for the rest of the process; it never evicts evidence to make state appear stable. The 64-ID bound is a defensive storage limit, not a measured supported-monitor count. A missing end callback can leave admission unavailable; subsequent native qualification must evaluate this behavior and recovery messaging.

## Sampling, capture and input

Native mode, bounds, online state and rotation are sampled between matching before/after tokens. CoreGraphics getters run outside the fence lock. A callback during those getters can therefore update the fence without acquiring the capture or injector lock; the crossed sample is discarded. Discovery and filter preparation are bracketed by the same configuration token, and the exact descriptor is checked again before native capture starts.

Queued observer delivery enters the existing current-resource lifecycle gate. It can retire an installed stream whose native start has not yet returned, as well as a running stream. It compares the current resource against the latest native state, so an old queued notification does not retire a replacement prepared under the latest configuration. Retirement uses the existing exact-stream stop receipt, synchronous peer/input invalidation and native cleanup barrier. The recovery episode keeps its five-start/30-second limit; notifications do not create a new budget for every callback.

Direct input reads the same fence through its native display-state provider. If the configuration changes between input admission and posting, or between text graphemes, the old session is retired and its held controls are released at their recorded global coordinates. Existing one-use descriptor-loss receipts remain bound to the old capture descriptor. Restoring dimensions cannot revive the session, and old receipts/input cannot release a replacement session's holds.

All display reconfigurations conservatively invalidate the captured configuration, including changes reported for another display. Global origins and main-display choice can depend on those changes. No new phone wire fields are introduced; recovery continues through the existing scoped input invalidation and new layout/hello exchange.

## Prepared regression evidence

Nine methods are authored and **unrun** in [ScreenCaptureSizingTests](../../../host-mac/RemoteDesktopHostTests/ScreenCaptureSizingTests.swift) and [ComputerUseTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseTests.swift):

- Registration failure, callbacks during registration, and one-shot registration completion.
- Multiple pending displays, duplicate begins, removal and post-change callbacks without a seen begin.
- A change that starts and finishes during a native-state sample, and rejection of reads while configuration is pending.
- Invalid IDs, bounded pending state and inability to reopen after overflow.
- Identical numeric display geometry under a different configuration token.
- Retirement during installed native startup and rejection of delayed success.
- Delayed observer/old-stream callbacks after replacement.
- Token change between input admission and posting, with held-control cleanup and no revival.
- Token change between text graphemes, preserving replacement input and its holds.

These fixtures use the pure fence, generic lifecycle with fake streams, fake display providers and captured event posters. They do not register the actual monitor or post input. The queued-delivery case composes the production current-resource gate and fence manually; it does not prove native callback scheduling, subscription deinitialization or the asynchronous monitor queue.

The [focused display-change inventory](capture-display-change-host-inventory.json) retains all 76 prior display/capture/input cases and adds nine named cases. Default and browser-host inventories are extended from their committed expected identifiers with those exact names. Source selection is not XCTest discovery or passing execution evidence.

Three changed Swift files pass parse-only checks. Static inventories select **1976 default host / 1293 focused browser-host / 85 focused display-change host** methods, with **32 capture-input client / 35 client-core** methods unchanged. Documentation validation checks **230 Markdown files / 1922 local targets / zero broken paths**. Whitespace validation is clean. The effective `.git/hooks` directory was inspected and contains **zero executable non-sample hooks**. Compilation, assertions, native execution and resource measurements remain deferred.

## Remaining repairs and later qualification

1. **Close actual content-placement and presentation evidence.** Bind content rectangles through scaling, padding, encoding and the owning renderer. Configured width/height and a decoded-frame probe do not prove the pixels actually shown or their hit-test mapping. See the [display repair sequence](CAPTURE_DISPLAY_BINDING_REVIEW.md#remaining-repair-sequence).
2. **Implement the bounded fresh-image request.** Retain exact capture/request/configuration ownership and actual native-operation capacity through cancellation and late callbacks. Do not invent capture freshness from callback time, or treat a still image as proof a suspended stream resumed. Follow the [fresh-image design](CAPTURE_FRESH_IMAGE_DESIGN_REVIEW.md#implementation-order-and-acceptance-requirements).
3. **Qualify notification and posting races after permission.** Exercise hotplug/removal, mode changes, rotation, mirroring, main-display changes and rapid change/return. Include delayed/blocked native event delivery, reconfiguration during getters/startup/posting, registration failure, unmatched begins and capturer teardown. The app cannot retract an already posted native event, and its token check is not atomic with OS reconfiguration. Async cleanup may be delayed by a blocked observer or capture consumer; posting/frame checks independently reject an observed old token, but actual held-release latency remains unmeasured.
4. **Qualify sleep, foreground and account handoff.** Online state alone does not prove a display is awake or drawable. Current capture-availability handling and this notification fence need native composition checks. Rearm source/presentation evidence on phone foreground return; preserve the exact paused login task until explicit Resume and fresh native account/page verification. No real login flow has been qualified by this change.
5. **Qualify complete user tasks and resources later.** Travel, concert and movie searches must exercise the actual planner, native browsing and verified live results. Alternative-model decisions and the RTX3080 desktop remain later measured work. No model quality, 8 GB memory, thermal or latency claim follows from this source repair.
