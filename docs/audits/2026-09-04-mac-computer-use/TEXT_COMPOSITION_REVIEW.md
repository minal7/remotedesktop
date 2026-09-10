# Soft keyboard composition and remote typing

Source repair, 2026-09-10, following `2a14395`. Native/UI/model execution remains deferred. This is a typing repair for manual browser/login handoff, not a qualification of that complete flow.

## First-principles findings

A proposed edit is not confirmed user text. Apple's [delegate contract](https://developer.apple.com/documentation/uikit/uitextfielddelegate/textfield(_:shouldchangecharactersin:replacementstring:)) asks whether UIKit should apply a replacement. [Marked text](https://developer.apple.com/documentation/uikit/uitextinput/markedtextrange) is provisional and may change before confirmation. The previous soft capture sent the delegate's replacement immediately, reset the local buffer to a space and returned false. It therefore had no local composition/confirmation path and did not distinguish candidate editing from committed remote text.

Text content also differs from a physical shortcut. The old path could map an uppercase letter to a Shift/key pair merely because the mapper added Shift. That assumes a host keyboard layout for ordinary text. Only an explicitly latched modifier should request that shortcut interpretation.

Native input callbacks do not contain our session/source token. Clearing a buffer and reusing the same native field under a new input generation cannot distinguish an old delayed commit from new input. Source retirement must also retire that native capture's ability to obtain a new source.

## Source changes

[KeyboardCapture](../../../ios/RemoteDesktop/Session/KeyboardCapture.swift) continues to use UIKit for composition. The field delegate now validates a local edit without sending it. `setMarkedText`, native replacement, composition insertion and `unmarkText` join nested native mutations before inspecting the resulting text. Marked content is retained locally. Deleting within that buffer stays local; Return with a current composition confirms it without issuing a remote Return command in that path.

An [UIKeyInput insertion](https://developer.apple.com/documentation/uikit/uikeyinput/inserttext(_:)) with no pending local composition sends the supplied string directly, retaining whitespace, Unicode and pasted line breaks. Post-mutation commits clear the local buffer before external transport callbacks and send through the captured source. Plain uppercase strings remain text. Explicit latched shortcuts, an empty-buffer Delete and an ordinary Return use an owned key-down/key-up pair. The local empty buffer no longer needs a space sentinel; `hasText` keeps remote Delete available. The soft keyboard requests the default keyboard type instead of an ASCII-capable layout.

Editing notifications outside the wrapped mutation calls use one cancelable actor task. It checks marked state after the native callback stack and retains the original source/modifier destination. A retired or replaced source cannot receive that deferred value. Native buffer clearing suppresses recursive commit work and cancels pending notifications. Resignation discards local composition before UIKit can unmark it; explicit dismissal/closure and source/window retirement also end capture.

Each native capture may own only one input source lifetime. It cannot rebind after retirement. Both [ordinary remote control](../../../ios/RemoteDesktop/Session/SessionView.swift) and [Computer Use](../../../ios/RemoteDesktop/ComputerUse/ComputerUseView.swift) identify the capture by `remoteInputGeneration`, so a new generation installs a new field. Initial admission failure can still retry before a source is ever acquired. Reopening a dismissed keyboard creates a new capture through the existing conditional view.

## Prepared cases and verification scope

Six new methods in [InputAndDiscoveryTests](../../../ios/RemoteDesktopTests/InputAndDiscoveryTests.swift) are authored and **unrun**. They cover proposal-only delegate callbacks and invalid ranges; exact uppercase/Unicode/whitespace insertion; provisional revisions with local deletion/confirmation; composition discard at focus/ownership boundaries; deferred callbacks after source replacement; reentrant replacement during delivery; and empty Delete/Return/explicit shortcut pairs. Four existing methods now invoke committed insertion and require replacement native fields after generation loss, rather than declaring a rejected delegate proposal to be a sent edit.

The [composition inventory](text-composition-client-inventory.json) adds the six new cases to the previous 80-method privacy inventory, which already selected the four revised cases. [Client core](../../../ios/AcceptanceFixtures/computer-use-client-core-tests.json) adds the same names to its previous 79. Historical identifiers are unchanged. Expected names derive from HEAD plus that explicit reviewed list, independently of source discovery.

These cases call UIKit methods on controlled capture objects; they have not been executed and do not emulate an actual language keyboard, keyboard-service process or user-visible login. No new model, host input protocol, runtime package or installed application was activated.

Static checks: four changed Swift files pass `swiftc -frontend -parse`. The inventories match 89 client-core / 86 text-composition-client and unchanged 1981 default host / 1298 focused host source identifiers. Local documentation validation finds 237 Markdown files / 2008 local targets / zero broken paths. Whitespace checks are clean, and the effective `.git/hooks` directory has zero executable non-sample hooks. No typecheck, build, assertion/test execution, native UI operation, model run or SSH retry occurred.

## Remaining qualification and repairs

1. Obtain later permission for a bounded build/typecheck and native keyboard qualification. Verify actual Pinyin, Japanese and Korean candidate entry, combining characters, emoji, dead keys, dictation, third-party keyboards and attributed marked input. UIKit callback order and whether native state exposes the intended final value remain unproven here.
2. Verify Return and candidate selection through actual keyboard events, including no duplicate Return after composition confirmation. Qualify multiline paste/replacement while composition is already active, context-dependent corrections and any native text normalization. Direct insertion coverage does not prove every native replacement route.
3. Qualify genuine responder loss, detachment/reattachment, SwiftUI identity replacement, accessory dismissal, backgrounding and privacy transitions. The native object cannot reopen after retirement; a detached capture may require explicitly reopening the keyboard. Discarding at resignation is not proof of complete focus-event history or rejection of every later callback within an otherwise unchanged input lifetime.
4. Preserve the existing remaining capture/presentation and physical-input handback requirements. Validate the exact paused browser task through manual sign-in and explicit Resume, then the complete travel/concert/movie workflows.
5. Keep runtime/model selection, alternate-model adaptation on the authorized RTX 3080 desktop, and measured 8 GB/thermal qualification at their deferred stage. No model failure was measured in this review; the confirmed defects were in application input handling.
