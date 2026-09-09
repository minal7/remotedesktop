# Reconcile recorded handback, Resume and sign-in lifetimes

Source checkpoint: 2026-09-09. Parent: `d7980f7`. Source repair and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

[Owner visits](BROWSER_OWNER_VISIT_RECONCILIATION_REVIEW.md) can identify exact native commits without proving how control moved through a login or Pause. A closed sign-in window is a window-lifecycle fact. Native reacquisition returning is a different fact. The research owner accepting Resume is another. Treating these as interchangeable would let an incomplete login, failed page check or intervening Pause masquerade as an accepted handback.

A failure is also different from a missing terminal record. A complete failure followed by a later valid explicit Resume can leave a reconciled history of the pause. The earlier failure must remain visible without permanently treating a later valid recovery as unfinished.

## Source changes

[ResultAssessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) now reconciles the immutable [control events](BROWSER_CONTROL_HISTORY_REVIEW.md) retained with each navigation reading. Native and workflow operation IDs remain separate. Pairs require the same full handback requirement, native parent session and ownership epoch, and correct record order. Native document generation and origin may legitimately change during login; their equality is not substituted for the handback's session binding.

A recorded workflow Resume requires its earlier recorded Pause, one correctly linked successful native handback, and the owner's separately recorded acceptance. An intervening Pause prevents the earlier operation from closing the pause. Reused IDs, overlapping workflows, missing native handback, foreign bindings and unmatched operations remain diagnostic gaps. A standalone native handback does not acquire a missing research-owner operation.

Admission of a new browser context has its own path. The owner's admitted-context event starts the pair, and its later acceptance can finish without inventing native reacquisition of the previous task. This follows the existing [admission implementation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift); no new control permission or transition was added.

Complete native and workflow failures have separate retained counts. A failed workflow keeps its pause open until a later valid operation closes it. A second Pause updates the pending pause state and invalidates an older Resume. The unclosed-pause count describes retained historical scopes; it is not a claim that a retired task is currently paused. Claim boundaries remain gaps because the existing Stop/claim marker is not an ordered terminal control event.

Sign-in opens and closes pair by exact window ID and parent session/epoch. Child observations must lie inside that window's recorded lifetime. Missing or overlapping lifetimes, open windows, observations outside a lifetime, and a claimed Resume while a sign-in window is open remain gaps. A sign-in window without a recorded research-owner Pause is identified as missing scope evidence, not as an unauthorized user action. Window closure creates neither native handback nor workflow-success credit.

Version 9 adds these separate counts and gaps to `control_history` inside the frozen navigation-history diagnostic. A matched set of recorded control episodes can resolve the generic control-episode gap; it does not establish complete observation coverage, authentication, current permission or source compliance. Claim/discard boundaries and control/observation overflow remain explicit gaps. [Planner instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserLinkPlanner.swift) explain the distinction. No native IDs, URL/origin data, handback seals or credentials are added to the model projection.

The [navigation-source completion gate](BROWSER_NAVIGATION_SOURCE_COMPLETION_GATE_REVIEW.md) remains active. The checker is read-only over bounded snapshots: it does not call an action gate, navigate, run inference, or change native/owner control state.

## Prepared coverage and allowed checks

Four new methods in [SourcePolicyTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSourcePolicyTests.swift) are authored and unrun. They use the existing trusted workflow-recording hook to exercise diagnostic sequences; they do not claim that these synthetic calls prove the real owner changed state:

- A paired workflow failure after native return remains visible after a later valid Resume closes the pause.
- A second Pause prevents an older Resume from succeeding even after native handback returned.
- Missing native handback and reused workflow identity cannot complete a recorded Resume.
- Standalone native handback cannot supply a missing owner Resume operation.

Six existing lifecycle/history scenarios gain assertions: real research Pause/Resume, a real authentication check failing after native return, [same-page reading freshness](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift), [new-context admission](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserAdmissionTests.swift), and [two sign-in window flows](../../../host-mac/RemoteDesktopHostTests/ComputerUseOwnedBrowserTests.swift). Two further diagnostic-version expectations are updated. Existing projection privacy assertions now cover the nested control diagnostic too.

Six changed Swift files passed `swiftc -frontend -parse`. Source inventories select 1633 default / 950 focused methods, four additions each and no removed or renamed identifiers. No JavaScript changed. These are syntax and source-inventory checks, not compilation or passing assertions. No app/browser execution, inference, SSH retry, push or installed-app replacement occurred.

## Remaining repair order

Source follow-up: [navigation-episode reconciliation](BROWSER_NAVIGATION_EPISODE_RECONCILIATION_REVIEW.md) now separates exact callback identities and native commit bases, including cached history paths. Observed-page adoption, response/redirect association, temporal scopes and platform qualification remain open.

1. Reconcile navigation callback episodes with dispatches and recorded control intervals. A matched owner Resume does not upgrade a pending-slot observation into an exact navigation identity or identify who initiated a script.
2. Give claim/retirement and unrecorded workflow scopes precise temporal semantics, and reconcile source-policy/goal lineage across manual login and legitimate clarification/replacement.
3. Qualify supported macOS/WebKit callback coverage and lifecycle behavior before replacing the navigation-source completion gate with affirmative evidence. Late changes must continue invalidating current use of old readings.
4. Continue account/document/form recovery, criterion replacement and semantic/model qualification in the [repair checklist](../../../TODO.md). Live travel, concert and movie scenarios and resource measurements remain deferred to explicit execution permission.
