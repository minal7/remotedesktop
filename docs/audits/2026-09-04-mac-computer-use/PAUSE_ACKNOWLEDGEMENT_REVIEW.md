# Take Control requests and host acknowledgements

Source repair, 2026-09-10, following `10598cb`. Native/UI/test/model execution remains deferred. This change makes handoff status more accurate; it does not qualify real account login or complete browsing tasks.

## First-principles findings

A local request, successful transmission, durable recovery record and received host acknowledgement are different facts. [ComputerUseSessionModel](../../../ios/RemoteDesktop/ComputerUse/ComputerUseSessionModel.swift) previously displayed “AI paused — you're in control” immediately on Take Control, before the Pause send completed. Its recovery initialization could display the same claim from a saved Pause intent or cached host state. The recovery field `hostControlPaused` is also assigned while allocating an outgoing intent, so it cannot independently prove acknowledgement.

Requiring a prompt-channel acknowledgement before every manual input would create another failure mode: a stalled TLS prompt channel could prevent takeover even while the direct-input channel remained usable. The existing [InputInjector](../../../host-mac/RemoteDesktopHost/InputInjector.swift) calls the automation interruption hook under its input posting lock before dispatching a valid direct-input packet. The [host manager](../../../host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift) records that intervention in its action gate before the MainActor lifecycle callback. The source therefore already provides a direct takeover boundary independent of prompt-channel acknowledgement. This is source evidence, not a new native verification result.

The host's `pauseExecution` closes action admission before cancellation and sends paused/intervention status. That status is not a receipt proving every already-dispatched native or browser operation has finished. Cancelling an executor and preventing its next gated effect do not make an earlier asynchronous effect disappear.

## Source changes

The client now retains one nonpersistent acknowledgement containing task ID, host epoch and applied phone revision. It records that fact only from a structured status after existing task, epoch, durable-revision and semantic-control checks, with exact host/pairing/session envelope scope. The fact is current only for the active paused task and current control clocks, without pending recovery/epoch failure, Stop or a reported connection interruption.

New Take Control, Resume and Stop requests clear the acknowledgement. A fresh prompt, terminal task cleanup and working/ready status also clear it. A restored model starts without an acknowledgement, even when its saved intent or host state was paused. The unscoped status helper cannot create one. Accepted typed host intervention can establish acknowledgement when its higher host epoch supersedes an older phone intent. Publication of status/progress/acknowledgement rechecks the active operation before continuing into the corresponding state update.

Take Control now reports that the request is waiting for the Mac. Recovery reports that it is confirming the saved request or checking the previous paused state. The [manual input strip](../../../ios/RemoteDesktop/ComputerUse/ComputerUseView.swift) distinguishes “Pause not yet confirmed” from “Mac acknowledged pause.” Restored intervention guidance remains available, but no longer automatically replaces the pending status with “Waiting for you.” The acknowledgement is a protocol fact, not a claim of instantaneous native quiescence or a new lease for dispatching input.

Manual screen/keyboard input remains governed by its existing current-screen, native focus, task and host interruption gates. This change introduces no extra server query, no new control command, no recovery schema change and no new model work. A successful send alone does not update the acknowledgement indicator.

## Prepared cases and source checks

Four new methods in [ComputerUseSetupTests](../../../ios/RemoteDesktopTests/ComputerUseSetupTests.swift) cover pending versus sent versus acknowledged Pause; old phone revisions across Resume/Take Control; foreign host/pairing/session/task scope; obsolete host epochs after local handback; restored paused state awaiting a new receipt; current host intervention; and rejection of acknowledgement inferred from an unscoped status helper. Five existing setup methods now distinguish pending/restored wording from accepted host status while preserving control revision and guidance checks. Two existing [WebRTC cases](../../../ios/RemoteDesktopTests/WebRTCTransportTests.swift) retain reentrant Take Control coverage and explicitly preserve manual keyboard availability before TLS acknowledgement.

Two deferred UI scenarios now require the stable acknowledgement accessibility value instead of the old optimistic manual-mode label: [guest sign-in](../../../ios/RemoteDesktopLiveE2ETests/OSAtlasDoorDashGuestSignInSimulatorLiveE2ETests.swift) and [capture-consent handoff](../../../ios/RemoteDesktopLiveE2ETests/OSAtlasDoorDashTakeoverResumeSimulatorLiveE2ETests.swift). They remain outside the deterministic client inventory and have not run.

These methods are **authored and unrun**. Fake channels and in-memory stores exercise client state and envelope handling; inert ticket prompts do not browse websites. The historical source inventory also selects existing methods that use other fixtures. No new native, transport or account-login result follows from these changes.

Expected names derive from HEAD plus the four new methods and five explicitly reviewed existing setup methods. [Client core](../../../ios/AcceptanceFixtures/computer-use-client-core-tests.json) selects 113 and the [acknowledgement inventory](pause-acknowledgement-client-inventory.json) selects 110. Default/focused host inventories remain 1981/1298. All four match source identifiers; six changed Swift files pass `swiftc -frontend -parse`, and whitespace checks are clean. No typecheck, build, assertion/test execution, app launch, native capture, CUA interaction, model run or SSH retry occurred.

Local documentation validation finds 240 Markdown files / 2037 local targets / zero broken paths. The effective `.git/hooks` directory has zero executable non-sample hooks. The installed Mac application and deferred performance stash remain untouched.

## Remaining repair and qualification list

1. Audit already-dispatched native/browser effects at takeover. Identify operations that can complete after the action gate closes, how their completion affects login focus/document state, and what must settle or be retired before handoff can be described as stable. A Pause acknowledgement is insufficient evidence for this property.
2. After explicit authorization, qualify actual host input-lock/action-gate ordering with cancellation-ignoring work, input during Pause/Resume delivery, lost acknowledgements, local Mac takeover, reconnect and process recovery. Preserve exact control revisions and host epochs; do not turn old status into a new command.
3. Review legacy unversioned lifecycle admission separately. The new acknowledgement fact requires structured, scoped evidence; this patch does not replace every historical status pathway or establish a general multi-controller lease. Retained acknowledgement describes an accepted control event, not continuous observation of the Mac.
4. Validate the actual pending/confirmed/recovery UI and accessibility presentation alongside keyboard focus and current-screen readiness. Failure to acknowledge must remain distinguishable from an unusable input channel or a storage failure, and manual takeover must remain usable when appropriate.
5. Complete sign-in by the person, host/browser handback after explicit Resume, and retained travel/concert/movie tasks with independently checked results. Native presentation/freshness, full natural-language correctness, alternate-model adaptation and measured 8 GB/thermal qualification remain open.
