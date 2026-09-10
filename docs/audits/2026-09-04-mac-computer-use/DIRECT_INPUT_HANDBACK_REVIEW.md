# Finish direct input before admitting automation

Source repair; execution pending. This continues the [input callback ownership repair](INPUT_CALLBACK_OWNERSHIP_REVIEW.md). No build, typecheck, assertion/test run, app/browser launch, model run, real-site task or SSH connection ran for this repair.

## First-principles findings

Handback requires more than an acknowledged command. The previous person's input must have finished, and an automation cleanup path must not modify input now owned by that person.

The [WebRTC delegate](../../../host-mac/RemoteDesktopHost/HostPeerSession.swift) previously called the interruption callback and then separately invoked the injector. Resume could reserve and activate automation after the callback had recorded its occurrence but before the direct event reached the Mac. Multi-grapheme text also released the injection lock between graphemes without retaining a packet-wide handback barrier.

The [injector](../../../host-mac/RemoteDesktopHost/InputInjector.swift) already retained keys and pointer buttons for their eventual release, but execution/approval admission did not consult that state. A remote drag or held keyboard modifier could therefore overlap a resumed task. A second ownership issue appeared in rejected AI input and AX writes: their cleanup released all held injector state, including a person's later drag or modifier.

## Repair

Authenticated direct input now enters `applyDirectInput`. Under the injector lock it registers a transaction, records the interruption and releases earlier automation-owned holds before assigning direct-input ownership. The complete packet remains registered until dispatch returns. Text keeps its existing per-grapheme lock yields; the transaction remains active between those yields. The callback no longer reacquires the same non-recursive injector lock. It still sends only the preceding one-use occurrence receipt to MainActor.

`admitAutomation` checks the registered transactions, held keys/buttons and pending Unicode stroke under the injection lock, then opens only the exact action-gate admission in that same critical section. Both normal execution activation and approved-action activation use this boundary. A held gesture leaves the task paused with release-and-Resume guidance, before invoking the executor or approved action. Admission does not synthesize a release to force progress. A later released gesture and explicit handback use the existing host epoch and original task/trusted-prompt paths.

Held-state ownership transfers to automation only after admission observes no remaining hold. Rejected AI key, text and AX operations now clean up only automation-owned holds. They cannot release the person's newer remote input. Explicit `releaseHeldInput` and the existing transport teardown still retire manual holds; they remain separate from a failed AI action's cleanup.

The transaction count and owner marker contain no input contents. Existing injector state continues to retain only the keys/modifiers/buttons needed to deliver and release input. No packet text, credentials or pointer data is copied into model context or handoff receipts by this repair.

## Prepared verification

Four new [host methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseTests.swift) are authored and unrun:

- Direct interruption precedes the first posted event; a repeated held pointer remains a drag, a held modifier blocks admission, and blocked AI key/text/AX operations cannot release either. Matching releases reopen admission. A Unicode text packet retains complete graphemes and records one interruption; non-input protocol messages cannot dispatch through this path.
- Local and phone Resume remain paused while a remote Shift key or mouse button is held. The browser owner and original trusted request survive; Resume does not force a key/button release. Matching release, current host epoch and later explicit Resume permit continuation.
- Input held before a new prompt prevents the first executor invocation. After release and current handback, the original task executes once.
- A held remote button blocks an approval response before the input's actor callback runs. The prepared continuation is cancelled, no approved action runs, the button remains held until release, and later Resume retains the original request.

The existing transport-release case now uses the actual direct-input transaction and confirms that explicit release permits admission. The browser fixture accepts a supplied injector so the input and manager share the same state as production. The [focused ten-method inventory](direct-input-handback-inventory.json) also retains prior paused-input, callback, successful-approval and native provider-popup cases.

Five Swift files pass parse-only checks. Source inventories select **1894 default host / 1211 focused host / 35 client core / 10 focused direct-input methods**. These are source and syntax checks, not execution, typechecking, event scheduling evidence or resource measurements.

Local documentation checks cover 214 Markdown files and 1,741 local targets with no broken targets. Whitespace checks are clean. The effective Git hook directory contains no executable non-sample hooks.

## Remaining repair and qualification sequence

1. Add and qualify physical-Mac gesture admission. The current native monitor omits key-up and mouse-up events and the new admission boundary checks injector-owned state only. It does not establish that physical keys, modifiers or buttons are released. Review OS state sampling, monitor completeness, startup with held input, local control activation and focus changes without recording key contents. Read-only local SDK declarations confirm that Quartz exposes key, button and flag state queries; no query was executed for this repair.
2. Qualify the packet transaction through real WebRTC and ordered-control composition, including interleaving between text graphemes, simultaneous release/Resume, cancellation, held Unicode strokes and stale executor cleanup. Authenticated packet admission versus disconnect and peer replacement also needs review: this change does not independently revoke an already admitted direct packet midway through dispatch.
3. Check held-state ownership through explicit releases and all custom injector/caller compositions. The production HostSession shares one injector with its manager and peer; fixture injection and alternative entry points must preserve that relationship. Source checks do not certify OS delivery, dropped events or modifier semantics.
4. Continue full browser/account handoff, native process recovery, whole-goal/action verification, broader clarification admission and conversational correction. Global navigation-source completion remains restricted pending qualification.
5. Keep test/model execution deferred. After correctness repairs, qualify lightweight models and total 8 GB Mac memory/thermal behavior. Alternative models and the reported RTX 3080 remain options; SSH access is still unverified after the earlier timeout. Retain real flight, concert, movie and login scenarios for later explicit permission.
