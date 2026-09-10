# Bind direct input to its authorized lifetime

Source repair; execution pending. This continues the [physical-input handback review](PHYSICAL_INPUT_HANDBACK_REVIEW.md) and [direct-input transaction repair](DIRECT_INPUT_HANDBACK_REVIEW.md). No build, typecheck, test/assertion run, app/browser launch, native input, model run, real-site task or SSH connection ran for this repair.

## First-principles findings

Permission is a relationship between a specific controller, connection lifetime and effect. A successful hello at an earlier point cannot authorize input after that lifetime ends. Checking permission before queueing work is insufficient when disconnect can occur before the effect. Cleanup is also an effect: an old controller releasing a key or button held by its replacement is an incorrect action.

The previous [peer session](../../../host-mac/RemoteDesktopHost/HostPeerSession.swift) used unsynchronized hello/capability fields. A transient disconnect notified the manager without clearing direct-input permission. Input already entering the injector had no retained authorization identity, including text that yielded between graphemes. Channel callbacks did not require an exact current channel, and peer close released shared input without identifying the input lifetime.

A second gap existed in the [manager's WebRTC fence](../../../host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift): it checked the peer generation under a lock, then released that lock before clearing input and closing the action gate. A replacement could arrive between the ownership check and cleanup.

Readiness also needs both the protocol hello and an active connection. These callbacks can arrive in either order. The [phone's ordinary connection and visual-sidecar paths](../../../ios/RemoteDesktop/SessionModel.swift) use hello acknowledgement as a readiness prerequisite. A host acknowledgement before input authorization could therefore expose a ready interface while valid initial commands were rejected.

## Repair

`HostPeerInputAuthorization` serializes channel ownership, hello capabilities, connection state and terminal closure. Only the current `control` channel may negotiate input; a different additional live channel is rejected. The current channel needs its own hello and a connected transport. Duplicate hello/connected notifications preserve its existing input lifetime. An incomplete initial handshake emits no control-loss notification, so merely opening a visual sidecar does not interrupt its live LAN task. Transient disconnect retires that lifetime; reconnect creates another. Terminal close is absorbing. Late callbacks and protocol errors from a former channel cannot close its replacement.

The [injector](../../../host-mac/RemoteDesktopHost/InputInjector.swift) issues an opaque `DirectInputSession` and requires that exact identity before recording an input occurrence and again at dispatch. Revocation and event posting share its lock. Non-text dispatch is checked while holding that lock; text checks again between whole graphemes, with each down/up pair kept together. Revocation can stop the remaining suffix without replaying the already-posted prefix. Packet-wide admission tracking still prevents automation from starting before the direct packet finishes.

Beginning or ending a current direct session releases that session's manual holds. Retiring an older session cannot release newer manual or AI holds. A stale packet rejected between graphemes performs no cleanup against its successor. The optional fixture hook runs after a complete grapheme, outside the lock, and receives no key/text data; production does not supply it.

Authorization notifications publish in transition order under the peer-authority lock. Its callback must not re-enter that authority. The current callback performs a synchronous manager fence and queues the actor update. The manager now keeps the generation check and synchronous release/interruption within `performIfOwned`, so owner replacement waits for that checked effect. This closure must not re-enter its fence or wait on MainActor. The reviewed lock order is peer authority, manager ownership fence, injector, action gate; the authority's earlier injector retirement finishes before entering the manager fence. No reverse acquisition was found in these paths.

The host sends hello acknowledgement/display only when the channel is open and an input session exists. Both valid-hello and connected callbacks attempt that send, covering either initial ordering. This is a readiness check at the send boundary, not a promise that the connection cannot immediately fail afterward.

## Prepared verification

Six new [host test methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseTests.swift) are authored and unrun:

1. Hold an authorized old cleanup while another queue attempts owner replacement; replacement input must begin after cleanup and survive a later old-generation callback.
2. Require hello and connected state in either order, retain a lifetime across duplicate hello, renew after disconnect, reject old captured sessions and prevent terminal revival.
3. Reject additional/foreign channels, require fresh hello on channel replacement, and preserve replacement holds against late old-channel close/hello callbacks.
4. Reject stale pointer, key, scroll and text packets without occurrence callbacks, input posting or release of newer manual/AI holds.
5. Disconnect/reconnect between complete text graphemes; only the first emoji down/up pair may post, and newly held replacement input must remain held.
6. Stop an old task, reconnect and start another; an old captured packet cannot pause the replacement task, while current direct input still can.

Five existing direct-input/handback methods now supply explicit input sessions. The [14-method focused inventory](direct-input-session-inventory.json) also retains ordinary hello classification, manager generation cleanup, held-input admission, physical handback and native provider-popup coverage. Four Swift files pass parse-only checks. Source inventories select **1905 default host / 1222 focused host / 35 client core / 14 focused input-session methods**. These are syntax/source checks, not typechecking, test discovery or executed assertion results.

Documentation checks cover 216 Markdown files and 1,760 local targets with no broken targets. Whitespace checks are clean. The effective Git hook directory contains no executable non-sample hooks.

## Remaining sequence and limits

1. **Separate local dispatch identity from wire freshness.** The token is created and checked inside the host; it is not carried by protocol-v1 input. A packet buffered inside WebRTC and first delivered after reconnect can acquire the new host token. The [wire protocol](../../../protocol/PROTOCOL.md) has sequence/timestamp fields but no negotiated input-session identity. Review a compatible sender/receiver generation and acknowledgement contract, input sent during disconnect, old queued releases, ordering/reliability enforcement and explicit recovery behavior before claiming stale network input is rejected. No complete replay or network-freshness guarantee follows from this repair.
2. Qualify actual RTC callback ordering, both hello/connection orders, acknowledgement delivery/failure, channel close/reopen, transient ICE recovery and teardown with in-flight input. The helper fixtures do not execute native RTC/media code. Existing media properties and teardown scheduling need their own concurrency qualification.
3. Run the prepared manager/injector cases when execution is authorized, then compose them with current source authorization, actor-epoch delivery, paused-input ordering, Stop/Resume, provider login handoff and stale executor cleanup. The concurrency fixture uses bounded waits but remains unexecuted.
4. Continue physical-event chronology and permission/monitor qualification from the prior review. Native OS event delivery is not proved by a captured synthetic-event fixture. Login completion still needs fresh page evidence after explicit handback.
5. Continue whole-goal browser results, durable native/process recovery and broader natural-language qualification. Global navigation-source completion remains restricted. Retain flight, concert, movie and account-login scenarios for later explicit live-test permission.
6. After correctness repairs, measure model failures and total 8 GB Mac resource budgets before choosing another model or distillation/pruning. The user-authorized RTX 3080 desktop remains an option; SSH access is unverified after the earlier timeout. No remote work or model change was attempted here.
