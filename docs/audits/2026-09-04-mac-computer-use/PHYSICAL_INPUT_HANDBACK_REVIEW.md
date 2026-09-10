# Sample physical input before handing control back

Source repair; execution pending. This continues the [direct-input handback repair](DIRECT_INPUT_HANDBACK_REVIEW.md). No build, typecheck, assertion/test run, app/browser launch, native input-state query, model run, real-site task or SSH connection ran for this repair. Local SDK headers were read as documentation.

## First-principles findings

A finished remote-input packet does not prove that the Mac's physical keyboard or mouse is released. Likewise, an event callback and current device state answer different questions: the callback reports an event the app received; a current-state sample can reveal a hold whose event has not reached that callback.

The [injector's admission boundary](../../../host-mac/RemoteDesktopHost/InputInjector.swift) previously checked only its own held state. A person could still be holding a physical key, modifier or mouse button when Resume activated automation. The [manager's native event mask](../../../host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift) also omitted key-up and mouse-up events, leaving release activity out of paused-input ordering.

The current SDK's `NSEvent.h` documents current modifier/button state as independent of event delivery, global monitors as asynchronous, and local monitors as unable to observe every nested tracking-loop event. `CGEventSource.h` supplies current key-state queries. `IOKit/hidsystem/ev_keymap.h` defines 256 native key codes. These declarations support bounded admission sampling; they do not establish complete physical event history or atomicity with OS delivery.

## Repair

Production admission now samples current combined-session key state, momentary modifier flags and the full AppKit mouse-button mask while holding the injector lock. The key scan covers codes 0 through 255, including codes outside the app's wire HID mapping. Mouse buttons and momentary modifiers are rechecked after the scan. Caps Lock and numeric-pad flags alone do not represent a held gesture; an actual down key still does. The sample is taken only at admission, with no polling loop or retained key history.

The sampler requires Accessibility trust before reading input and checks it again before accepting a released sample. Held input and unavailable observation are distinct results. Both keep the action claim closed; the manager retains the paused task and explains either release-and-Resume or the need to check Accessibility access. Normal task activation and approval acceptance share this boundary. They cannot synthesize a release to manufacture a successful handback.

The native event mask now includes key-up and all three mouse-up categories. The same classification filters events before they enter the occurrence/receipt path. A real release while paused updates its input generation, so a delayed remote Resume must receive the new host epoch. The host's own tagged synthetic releases are excluded. Local control activation can still acknowledge the input preceding its explicit handback; further input remains an interruption.

Production admission also requires both local and global monitor registrations. An incomplete registration is removed and retried on a later admission attempt; failure keeps the task paused. Shutdown removes registrations after closing the action gate. Ordinary Stop retains monitoring for a later task. Registration, retry and removal are source changes without executed AppKit qualification.

## Prepared verification

Five new [host methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseTests.swift) are authored and unrun:

- Sampler fixtures cover no reads without trust, all 256 key queries for a released sample, boundary and Caps Lock key codes, each momentary modifier, an additional mouse button, changed aggregate state and lost trust during sampling.
- Held and unavailable physical state cannot invoke the action-gate activation closure. A later released state can activate the same still-closed claim without posting input.
- Local and phone handback preserve the browser owner, paused task and original trusted request while observation is held or unavailable, then permit an explicit later Resume after release/restoration.
- Untagged key-up and mouse-up events advance paused-input ordering. Tagged host releases do not invalidate the next current Resume. Test event objects are created but never posted.
- Physical state blocks initial executor invocation and approved-action execution. Later release preserves the original request, and a blocked prepared approval is cancelled rather than reused.

The [focused ten-method inventory](physical-input-handback-inventory.json) also retains remote held-input, local-button intent, ordinary approval and native provider-popup coverage. Three Swift files pass parse-only checks. Source inventories select **1899 default host / 1216 focused host / 35 client core / 10 focused physical-input methods**. These are syntax and source checks, not typechecking or assertion results.

Local documentation checks cover 215 Markdown files and 1,748 local targets with no broken targets. Whitespace checks are clean. The effective Git hook directory contains no executable non-sample hooks.

Deterministic XCTest instances use released physical state unless an explicit sampler is supplied, so a person typing on the test Mac cannot change unrelated fixture outcomes. Native qualification must explicitly inject `InputInjector.readCurrentPhysicalInputState` and exercise real devices/OS delivery. The new fixture tests do not establish actual hardware, permission or AppKit monitor behavior.

## Remaining sequence

1. Qualify the real sampler and event monitors when execution is authorized: startup with keys/buttons held, left/right modifiers, Caps Lock, Fn, extended keyboards, mouse buttons, dragging, focus changes, menu/control tracking and local Resume activated by keyboard or mouse. Exercise Accessibility loss/restoration, failed monitor registration, retry and shutdown cleanup.
2. Review ordering between OS samples and delayed monitor delivery. A scan is not an atomic device snapshot, and callbacks arriving after an explicit handback can still describe earlier physical input. Completed gestures occurring wholly between samples require additional causal evidence; no comprehensive event-history claim follows from the sample. Secure-input and platform-specific state visibility also need qualification.
3. Review authenticated direct-packet admission versus disconnect and peer replacement, including packets already dispatching between graphemes. Continue packet/held-state ownership qualification through stale executor cleanup and transport teardown.
4. Continue browser/account handoff, native process recovery, whole-goal/action verification, broader clarification admission and conversational correction. Global navigation-source completion remains restricted pending qualification.
5. Keep test/model execution deferred. After correctness repairs, qualify lightweight models and total 8 GB Mac memory/thermal behavior, including admission-sampling cost. Alternative models and the reported RTX 3080 remain options; SSH access is still unverified after the earlier timeout. Real flight, concert, movie and login scenarios remain for later explicit permission.
