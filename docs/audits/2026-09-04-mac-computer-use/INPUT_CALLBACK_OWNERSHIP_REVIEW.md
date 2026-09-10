# Keep delayed input callbacks with the interrupted execution

Source repair; execution pending. This follows the [paused-input ordering repair](PAUSED_INPUT_ORDERING_REVIEW.md). No build, typecheck, assertion/test run, app/browser launch, model run, real-site task or SSH connection ran for this repair.

## First-principles findings

A native input event and the later UI update describing its interruption are different moments. Closing injection immediately protects the first moment; the later callback also needs ownership. It cannot infer which task was interrupted from whichever task happens to be current when it finally runs.

The [Mac event monitors and manager](../../../host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift) and [direct phone-input callback](../../../host-mac/RemoteDesktopHost/HostSession.swift) previously carried a Boolean across the MainActor boundary. After closing the gate they queued an unscoped `userIntervened()` call. Stop and a new prompt could replace the current context before that call ran. The old callback would then close the replacement's gate, cancel its execution and persist a Pause for the wrong task. The same issue applied to a new Resume admission for the same task ID.

The review also found that entering approval unconditionally recreated approval ownership. A visual or MCP result could arrive after input synchronously closed the action gate but before the actor callback surfaced that interruption. Installing a fresh approval wait in that interval made a later approval capable of reopening the gate.

## Repair

The action gate now creates a one-use input-intervention receipt under the same lock that revokes the pending, active or approval claim. The receipt contains an opaque identifier, with no key contents, text, pointer position, account information or page data. Repeated events after that synchronous close cannot replace the outstanding receipt. Input during an already-paused handoff still uses the prior coalesced occurrence marker and creates no actor work per event.

The injector's existing event-posting lock still encloses that close and releases held direct input only when automation was interrupted. Both production input callbacks capture the returned receipt and pass it to `applyUserInputIntervention` on MainActor. That method consumes only the exact retained receipt before invoking the existing lifecycle pause. Consumption is one-use. Pause, Stop, completion and a new admission retire the previous receipt; a callback from the old execution cannot consume a newer input receipt or affect a replacement manager's gate. A resumed execution has a fresh admission even when its task ID is unchanged.

Synchronous authorization/disconnect lifecycle calls retain their separate existing API. They do not invent physical-input receipts. Their existing peer-generation and authorization checks remain required.

Approval admission now atomically requires an active, open automation claim before switching into approval wait. If input has already revoked that claim, the manager cancels the exact prepared visual continuation or MCP work and keeps the original context paused. It does not install or deliver the approval card. Input after approval admission can still revoke that held claim; the existing approval-acceptance guard then refuses to execute it. Normal approval delivery and explicit later Resume use their existing paths.

## Prepared verification

Five new [host regression methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseTests.swift) are authored and unrun:

- Pending, active and approval interruption receipts are one-use, survive a burst without replacement, cannot consume another receipt and retire at completion, Stop or new admission. An interrupted gate cannot enter approval wait or reopen on completion.
- A delayed callback from a stopped task cannot pause a new task waiting for its cancellation-ignoring predecessor. The predecessor's stale tool call remains blocked, and the replacement can then execute.
- A same-task Resume retires old receipts, while new input during pending admission and active execution still pauses that exact continuation. Duplicate delivery cannot advance the host epoch again or erase a newer receipt.
- Input during visual approval target preparation cancels the continuation, publishes no approval card or action and retains the original trusted request for Resume.
- Input before MCP approval admission cancels prepared work, invokes no approved helper action, publishes no approval card and keeps the original task resumable.

The existing pending-approval input case now uses the actual receipt path, including duplicate delivery, with an explicit target fixture and a failing action spy. Earlier paused-input/readiness cases are updated for the optional receipt return value. The [focused twelve-method inventory](input-callback-ownership-inventory.json) also retains successful approval, denial, synchronous approval-acceptance interruption, paused-input and full native provider-popup coverage. Fixture and inventory source changes are not executed evidence.

Three Swift files pass parse-only checks. Source inventories select **1890 default host / 1207 focused host / 35 client core / 12 focused callback methods**. Syntax and source registration do not establish type correctness, assertion results, native event scheduling, provider compatibility or model quality.

Local documentation checks cover 213 Markdown files and 1,733 local targets with no broken targets. Whitespace checks are clean. The effective Git hook directory contains no executable non-sample hooks.

## Remaining repair and qualification sequence

1. Keep execution deferred. When authorized, compile and execute the selected cases and the real event-monitor/phone callback composition. Exercise reordered delivery through Stop, replacement, Resume, approval preparation and approval acceptance; verify that one interruption changes only its owning execution.
2. Review full gestures and held-input state at handback, including modifier/key release, pointer release, dragging, focus changes and local Resume activation. Receipts order callbacks already captured by the host; they do not prove ordering or completeness of operating-system event delivery.
3. Qualify cross-device transport and storage timing together with provider-window continuity. Native browser/account reconstruction after process loss remains incomplete; neither in-memory receipts nor absent paused-input history authorize reconstruction.
4. Continue whole-goal/action verification, bounded progress, broader clarification admission and conversational correction. Global navigation-source completion remains restricted pending qualification.
5. After correctness repairs, qualify model competence and total 8 GB Mac memory/thermal behavior. Alternative models and the reported RTX 3080 desktop remain options; access remains unverified after the earlier SSH timeout. Keep real flight, concert, movie and account-login scenarios for later explicit permission.
