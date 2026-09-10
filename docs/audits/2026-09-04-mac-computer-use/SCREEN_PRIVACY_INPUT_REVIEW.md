# Screen privacy and direct-input ownership

Source review and repair, 2026-09-10. Runtime checks remain deferred by the user. This review does not qualify browser tasks, native presentation, login or inference.

## First principle and confirmed gap

A person cannot safely direct input at pixels the app deliberately conceals. Disabling one view's hit testing is insufficient: a keyboard responder, latched modifier or queued source callback can still reach the transport. Existing Computer Use privacy shielding hid pixels and disabled screen touches, while `SessionModel.hasInteractiveRemoteScreen` and its send path did not include that policy. Approval backdrops also depended on view-level blocking.

## Source repair

[ComputerUseSessionModel](../../../ios/RemoteDesktop/ComputerUse/ComputerUseSessionModel.swift) now reports persistent shielding and approval-screen obscuration synchronously to its owner. The [session](../../../ios/RemoteDesktop/SessionModel.swift) binds that callback to the exact current prompt model, clears the previous binding and samples restored policy when installing a model. Old callbacks cannot cover a replacement session.

New input admission reads both the current requested policy and the session's committed gate. Every public direct-input path uses it. Private cleanup can still release owned keys, buttons and scroll gestures under the old input generation. A privacy edge inside an existing source release waits for all releases in that scope; new input is already denied during this interval. Input generation changes only after cleanup and only for the owner/generation that initiated it. Nested reveal or replacement is sampled again rather than overwritten with an old requested value.

Prompt submission and approval handling recheck their task operation after privacy callbacks. A synchronous disconnect or task change during cleanup cannot let the interrupted request proceed to new storage/submission work. Existing completed storage operations are not rolled back or silently replayed.

[ComputerUseView](../../../ios/RemoteDesktop/ComputerUse/ComputerUseView.swift) distinguishes transport/submission readiness from permission to interact. Its Show Mac control remains reachable while persistent shielding blocks input. Approval obscuration remains independent: Show Mac does not dismiss an approval card. Closing the gate also withdraws takeover keyboard UI through its existing interactivity observation. Revealing allows new sources, while retired source leases and generations stay rejected. The TLS prompt session is retained; this policy does not start, stop or replace its visual transport.

## Prepared regression cases

Six methods are authored and **unrun**:

- All owned keyboard, modifier, pointer and scroll releases precede retirement; raw/leased hidden input is rejected and only new sources work after reveal.
- A reveal during cleanup cannot admit reentrant input or restore old source ownership.
- A shield requested during multi-key cleanup preserves every remaining release.
- Disconnecting during privacy cleanup prevents the interrupted prompt from being appended/submitted.
- A retained old privacy callback cannot affect an ordinary replacement session.
- A non-Mail approval obscures input policy; Show Mac cannot dismiss it; responding clears that separate policy while preserving the task.

The first five are in [WebRTCTransportTests](../../../ios/RemoteDesktopTests/WebRTCTransportTests.swift), using recording transports and an idle channel. The final case is `RemoteScreenObscurationTests` in [ComputerUseClarificationClientTests](../../../ios/RemoteDesktopTests/ComputerUseClarificationClientTests.swift), using its scripted in-memory channel. These fixtures do not capture pixels, run inference, log into accounts or validate native keyboard responders.

The [privacy inventory](screen-privacy-client-inventory.json) extends the prior 74-method producer inventory with the six explicit names. [Client core](../../../ios/AcceptanceFixtures/computer-use-client-core-tests.json) extends its prior 73 names with the same six. Historical inventories are unchanged. Expected names are selected from HEAD plus the reviewed list, independently of source discovery.

Static verification: five changed Swift files pass `swiftc -frontend -parse`; source inventories select 79 client-core / 80 screen-privacy-client and unchanged 1981 default host / 1298 focused host identifiers without drift. Documentation validation finds 236 Markdown files / 2001 local targets / zero broken paths. Whitespace validation is clean. The effective `.git/hooks` directory contains zero executable non-sample hooks. No build, typecheck, XCTest/assertion execution, native UI operation or model run was performed.

## Remaining repair and qualification list

1. Finish [presentation integration](PRESENTATION_PRODUCER_REVIEW.md) with complete supported frame formats and distinct candidate-pixel/input permission. Current readiness still means a valid frame was forwarded into the current renderer, not that fresh pixels were visibly presented.
2. Rearm presentation/freshness across privacy, viewport, activity and account transitions. This change retires input leases; it does not establish a new capture-to-drawable witness after Show Mac.
3. With later explicit permission, verify actual opaque layering, approval animations, hardware/soft-keyboard focus and held-control release on the installed client/host. Source fixtures cannot establish those native behaviors.
4. Qualify the same paused login task through person-controlled sign-in, explicit Resume and fresh account/page verification. An idle TLS fixture is not that scenario.
5. Then qualify bounded real travel, concert and movie tasks, followed by measured model selection and 8 GB resource work. Alternative models and the authorized RTX 3080 desktop remain options; no model execution or SSH retry was performed here.
