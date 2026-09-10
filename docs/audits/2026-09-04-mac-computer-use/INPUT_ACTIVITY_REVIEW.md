# Retire phone input when its app or scene becomes inactive

Source repair; execution pending. This follows the [input-source ownership repair](INPUT_SOURCE_OWNERSHIP_REVIEW.md). No build, typecheck, test/assertion execution, app/device/browser operation, model run or SSH retry was performed. Apple documentation was read to check native lifecycle notification semantics. Real travel, concert, movie and login scenarios still require later explicit permission.

## First-principles findings

A mounted view is not evidence that a person can still interact with it. System interruptions, an inactive scene and backgrounding can leave the keyboard and pointer surfaces attached. Their transport can remain connected too. The prior source cleanup handled device/view replacement, window removal and account freezing, but the app had no application or scene activity gate. A held key or drag could survive an interruption until some unrelated teardown occurred.

Closing a gate before releasing the holds creates another failure: the release is rejected while the host still has the original down. Release and revocation therefore need an ordered transition. New input must be rejected during that transition, and subsequent callbacks must carry retired source identities. Application activity and scene activity are independent requirements; one becoming active cannot override the other's inactive state. Old scene notifications must not control a replacement scene.

Apple documents that [a scene's will-deactivate notification](https://developer.apple.com/documentation/uikit/uiscene/willdeactivatenotification?changes=__3) precedes loss of interaction, covers temporary interruptions and background transitions, and identifies its scene in the notification object. Apple also distinguishes scene callbacks from [application notifications for aggregate application state](https://msc-kobol-public-prod.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle). The implementation uses native notifications at those boundaries rather than inferring activity solely from a later view update.

## Source repair

The [session model](../../../ios/RemoteDesktop/SessionModel.swift) starts with direct input closed. `RemoteInputActivity` requires both the application and its owned scene to be active. This requirement composes with the existing account, hello/display/frame and source-identity gates. Gaining activity cannot bypass an unavailable transport or pending account revalidation. Existing deterministic presentation/input fixtures now explicitly supply active activity and isolated notification centers; production uses the closed default.

Application will-resign-active, did-enter-background and will-terminate notifications request inactive state. Did-become-active updates only application activity. The model removes its observers on deinitialization. Termination handling is best-effort notification cleanup; it is not a guarantee that the operating system will deliver a termination notification or transmit the final releases before killing the process.

The [root app](../../../ios/RemoteDesktop/App.swift) installs an invisible UIKit view that binds to its actual containing window scene. It registers scene-specific will-deactivate, background, disconnect and activate observers. A newly bound scene samples application and scene activity to cover attachment after activation. Ordinary view updates do not resample and overwrite a just-received will-deactivate edge while UIKit still reports its prior activation state.

Each scene binding gets a private lease. Replacement first retires old input even if both scenes report active. Scene callbacks and cleanup require the current lease; an old scene cannot reopen, deactivate or remove its successor. Window removal and explicit dismantle remove observers and retire that binding. The current app manifest disables multiple scenes, but the implementation still checks ownership instead of assuming every notification describes the current window.

On an active-to-inactive transition, the model rejects new source admission and input during the synchronous release batch. The internal release path still requires the original input generation and current transport/account/readiness gates. It releases tracked keyboard, pointer/scroll and soft-modifier holds before publishing inactivity, then changes the local generation. Old text, key, pointer, scroll and modifier callbacks remain retired after activity returns. Duplicate inactive edges do not repeat releases or unnecessarily change the generation.

Lifecycle requests arriving synchronously from a cleanup callback update a separate desired activity state. The transition finishes cleanup and then applies the latest independent application/scene state. A later activation is not lost, and application activation does not overwrite a scene's deactivation. Scene leases are reserved or removed before transition callbacks so reentrant replacement cannot be cleared by old cleanup.

The ordinary [session interface](../../../ios/RemoteDesktop/Session/SessionView.swift) and [Computer Use interface](../../../ios/RemoteDesktop/ComputerUse/ComputerUseView.swift) explain that the person must return to the window to control the Mac. Existing generation/readiness handling closes remote keyboard UI and resets capture state. Activity loss does not stop, restart or resume `ComputerUseSessionModel`; it does not reroute direct input onto TLS, replace the browser owner, or declare login complete. Native AI/task/approval policy remains separate.

## Prepared evidence and limits

Eight new methods are authored and **unrun** in the [input fixtures](../../../ios/RemoteDesktopTests/InputAndDiscoveryTests.swift) and [transport composition fixtures](../../../ios/RemoteDesktopTests/WebRTCTransportTests.swift):

- Start closed and require both activity dimensions, in either activation order, before admitting a source.
- Release key, drag, scroll and modifier holds before each application inactivity notification closes admission; ignore duplicate edges and retired input.
- Keep an inactive scene closed when the application activates, and require a new source after the scene returns.
- Reject old scene activation, deactivation and cleanup after replacement.
- Reject input attempted from a synchronous release callback while retaining later application and scene lifecycle requests.
- Keep transport recovery and account revalidation closed despite activity returning.
- Keep a still-mounted soft field retired until explicit UI rebinding after activity loss.
- Send sidecar cleanup through the visual transport while retaining the existing ready prompt-session object/state and rejecting inactive or retired input. This fixture does not contain an active or paused AI task; it does not qualify real task continuation, login handback or operating-system background networking.

The [28-method source inventory](input-activity-client-inventory.json) includes these eight and the prior twenty source/presentation methods. Default host and focused host inventories remain **1912 / 1229**; client core remains **35**. Seven changed Swift files pass `swiftc -frontend -parse`; source inventory selection and whitespace checks match. The documentation scan checks 221 Markdown files and 1817 local targets with no broken paths; the effective `.git/hooks` directory has no executable non-sample hooks. These checks do not establish iOS compilation, rendered UIKit behavior, executed assertions or host input effects.

## Remaining sequence

1. Prove capture freshness for input recovery and foreground return. This repair retains transport presentation evidence across an activity interruption. Activity returning is not evidence of newly captured pixels, and a later decoder callback is also insufficient by itself. Establish a native capture/frame identity boundary before claiming that resumed input targets a current Mac screen. Do not treat a fixture's explicitly delivered frame callback as this proof.
2. Qualify real UIKit scene/application ordering, Control Center/system alerts, split-view interruptions, lock/unlock, window attachment/removal, keyboard holds, drag/scroll release, GameController reconnect behavior and queued callbacks. The prepared scene tests exercise model leases; they do not create a real window scene or deliver actual UIKit lifecycle events.
3. Review focus changes within an otherwise active scene, input responder/IME semantics, lock keys and multiple coalesced keyboards. Scene activity does not by itself identify the text field that owns a particular key.
4. Establish failure cleanup when the app is suspended or killed before releasing input. Native data-channel ordering, transport loss/timeout detection, host release effects and input-age limits remain relevant. A best-effort will-terminate handler cannot prove process-death cleanup.
5. Continue explicit native login Resume and fresh page verification, whole-goal browser results and bounded natural-language task qualification. Preserve the Mac's native task owner while the phone is inactive; do not infer authentication or successful handback from app activation.
6. Keep model execution, alternative-model selection/distillation and 8 GB memory/thermal qualification deferred until correctness work is ready for that stage. The RTX 3080 desktop remains authorized for later measured model work; its earlier SSH timeout remains unresolved.
