# Release input under the view or device that owns it

Source repair; execution pending. This continues the [presentation recovery review](INPUT_PRESENTATION_RECOVERY_REVIEW.md). No build, typecheck, test/assertion execution, app/browser/device interaction, model run or SSH retry was performed. The supported 8 GB Mac target and later explicit permission for real-site tasks remain unchanged.

## First-principles finding

A wire connection can stay authorized while its keyboard or pointer view disappears. Clearing a callback or a local Boolean cannot undo a key-down or mouse-down already admitted to the host. Conversely, sending an unconditional key-up from a disappearing view can release a key that its replacement now owns. Connection identity solves transport replacement; it does not identify concurrent or successive local input sources.

The previous hardware coordinator removed its handler without retaining its forwarded key holds and did not observe keyboard disconnect. The text field checked only the connection's generation, so two successive fields in that same generation could both send text. The pointer surface had no explicit dismantle cleanup, could retain a renderer after window removal, and an old surface could clear a replacement's zoom callbacks. Soft modifiers and hardware keys could also use the same HID usage, making independent unconditional release incorrect.

The required ownership is a hierarchy: current authenticated input connection, current local source registration, then that source's admitted key/button state. A source ending must first lose permission to append input. It can then release only holds no longer owned by any other current source. Replacing a source must finish its cleanup before admitting the successor. Losing the connection discards local ownership; the host's transport lifetime handles remote cleanup, because sending those old releases into a new connection is incorrect.

## Source repair

The [session model](../../../ios/RemoteDesktop/SessionModel.swift) now issues an opaque lease for each of four bounded source kinds: hardware keyboard, soft keyboard, soft modifiers and pointer surface. Each lease contains the current input generation and a unique registration identity. Admitting a replacement retires the previous same-kind source first and rechecks readiness afterward, including synchronous transport loss during cleanup. The input-generation reset discards all source records.

All production capture paths send through their lease. Source admission rejects stale identities, unmatched key releases and message kinds that do not belong to that source. Key state is retained per source and combined for release decisions. A second source claiming an already-held key does not send another initial down, and its later release cannot release the other owner. Repeated down events from an existing owner remain permitted. Momentary modifiers held by either keyboard or the soft bar are included in other key packets. Releasing soft modifiers retires that source instead of emitting independent key-ups. Disconnect/reset release all tracked sources before transport teardown. Account revalidation also releases all sources before freezing outbound admission, then changes the local generation so old callbacks cannot return after a same-account check. Previously that freeze released only soft modifiers; later view cleanup could no longer send hardware/button releases through the closed gate.

Cleanup removes the registration before sending. Ordinary keys are released before modifier usages, and each release retains the remaining sources' modifier state. Pointer cleanup releases its last admitted button mask at its last admitted pointer coordinates. An active scroll receives a zero-delta end at its own recorded coordinates. Each generated packet still passes the original connection-generation and readiness gate. These records describe local admission, not proof of native delivery or macOS application effect. Native send failure continues to use the existing transport teardown path.

The [hardware coordinator](../../../ios/RemoteDesktop/Session/KeyboardCapture.swift) explicitly retires the previous coordinator on replacement. Session changes release the old source before rebinding. Disconnect notifications retire only the currently registered keyboard device; reconnect attaches a fresh lease. Stop removes both observers and the owned handler. Callback registration identity and the source lease are both checked. A newly bound keyboard already holding keys remains suppressed through release as in the prior repair. Actual GameController coalescing, disconnect notification timing and held-state sampling remain unqualified.

The soft field owns a distinct lease. Rebinding another field in the same connection invalidates the old field, and an ordinary update of that old field cannot reclaim the same generation. Window removal retires its binding; window reattachment may explicitly acquire a new one. Dismantle permanently stops capture, retires the lease before resigning/unmarking, clears its dismissal callback and prevents later rebinding. A retired field's accessory action cannot dismiss the current keyboard through its old callback.

The [pointer surface](../../../ios/RemoteDesktop/Session/RemoteScreenView.swift) retires its lease on session replacement, window removal and explicit dismantle. A superseded surface keeps its rejected lease until an actual binding boundary, so an old event cannot silently reacquire input. Only explicit UI binding or window attachment can acquire a source; an event callback can discard old state but cannot acquire the recovered registration. Availability reset clears its gestures and touch history. Renderer removal now covers window loss and permanent stop. Zoom callback cleanup and scale reporting check which surface currently owns the shared controller, so an old surface cannot disable or overwrite its successor's controls.

## Prepared evidence

Nine new methods are authored and **unrun** in the [input fixtures](../../../ios/RemoteDesktopTests/InputAndDiscoveryTests.swift) and [surface fixtures](../../../ios/RemoteDesktopTests/RemoteScreenInteractionTests.swift):

- Replace a hardware source with held command and character keys, then reject its late input and cleanup after the successor holds a key.
- Preserve shared hardware/soft modifier and character ownership, including modifier flags on another source's key events.
- End a pointer drag and scroll at their separately recorded coordinates before replacement; reject old continuation and cleanup.
- Discard old ownership on recovery and reject old-source release or creation in the retired generation.
- Lose transport synchronously during cleanup and withhold replacement admission; later recovery cannot inherit its pending releases.
- Release hardware, pointer and soft modifier holds before account revalidation closes admission, and retire their old generation.
- Reject unmatched releases, cross-kind input and control messages while retaining ordinary repeated key-downs.
- Replace and dismantle soft fields without allowing late text/delete or old rebinding into the successor.
- Replace and dismantle screen surfaces without disabling the successor's input and zoom controls; late events cannot acquire a recovered source.

The [20-method source inventory](input-source-client-inventory.json) includes these nine and the prior eleven presentation methods. Default host and focused host inventories remain **1912 / 1229**; client core remains **35**. Five changed Swift files pass `swiftc -frontend -parse`; source inventory identifiers and whitespace checks match. The local documentation scan checks 220 Markdown files and 1806 local targets with no broken paths. The effective `.git/hooks` directory contains no executable non-sample hooks. These are syntax and source-selection checks, not compilation, test discovery, assertion results or native behavior evidence.

## Remaining repair and qualification sequence

1. Establish recovered video capture identity. A decoder callback after a handshake still does not prove capture after that handshake. Keep native login handback separate from screen readiness.
2. A subsequent [activity source repair](INPUT_ACTIVITY_REVIEW.md) gates input on the app and owned scene, releases holds before inactivity and retires source generations without normal view dismantle. Qualify actual lifecycle/device behavior, then continue foreground capture freshness, focus within an active scene and process-death cleanup; termination callbacks are not guaranteed.
3. Review keyboard semantics beyond momentary held modifiers: Caps Lock/lock-state synchronization, multiple coalesced physical keyboards, repeat ownership, simultaneous touch and indirect pointer activity, shortcut versus Unicode text, IME composition and old responder callbacks after reattachment. A registration check cannot reconstruct input history the native API did not provide.
4. Qualify actual UIKit window/dismantle order, recognizer cancellation, GameController callback/disconnect order, native transport send failure and macOS release effects. The surface fixture checks source-facing enablement and ownership; it does not generate actual touch/device input or prove renderer lifetime behavior.
5. Continue browser/account-login handoff and full natural-language goal verification. Preserve explicit native Resume, a retained browser owner and fresh page evidence for authentication. The travel, concert and movie scenarios remain deferred until readiness is established and the user grants explicit permission.
6. Finish correctness work before alternative-model selection, distillation/pruning or resource qualification. The authorized RTX 3080 desktop remains a later option, with SSH access still unverified after the earlier timeout. No current model comparison, acceptable fan behavior or 8 GB suitability has been established.
