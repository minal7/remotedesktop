# Preserve the difference between login, native handback and workflow resume

Source checkpoint: 2026-09-09. Parent: `a4b14aa`. Control-history foundation and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

The [navigation observations](BROWSER_NAVIGATION_OBSERVATION_HISTORY_REVIEW.md) distinguish callback attribution and control-gate state. They do not establish when a workflow paused, whether a particular sign-in window closed, or whether native reacquisition actually led to a resumed research workflow.

These are separate facts. Closing a sign-in window does not prove authentication succeeded. Native handback can succeed for an unchanged document that still contains a login form. The research owner must then perform its page/authentication checks and validate its operation before leaving the paused state. Crediting either earlier event as successful workflow resume would invent a transfer the owner never accepted.

Separate event arrays also need a shared ordering. Without it, an observer cannot establish whether a navigation observation preceded a pause or occurred during a particular sign-in window's lifetime.

## Native and owner source changes

[ComputerUseOwnedBrowser](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) now retains control events alongside its navigation attempts and observations. The events distinguish workflow Pause, workflow resume start/success/failure, native reacquisition start/finish/failure, and sign-in-window open/close.

Native reacquisition validates the supplied session before opening an operation record. Its start and terminal event share a native operation ID. When called by research resume, they also retain that owner's exact resume operation ID. Foreign or retired session bindings cannot write a current control history. If identity is lost while the operation is suspended, the history does not fabricate a terminal event under the replacement context; missing continuity still requires reconciliation.

The event retains the full native handback requirement, including its presentation requirement, rather than relying only on a digest of session identity. It also retains the parent browser session, ownership epoch, generation and origin. Raw URL paths, queries, page content, credentials and error payloads are not added to this history. Descriptions expose only the event category.

[ComputerUseBrowserResearchTask](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) records Pause after setting its paused state and preserving its handback token. Resume start is associated with the newly reserved owner operation. A successful resume is recorded only after the existing native/page checks, cancellation checks, operation/epoch validation and actual owner state transition. Failure retains a separate workflow outcome when a current session binding remains available. Recording these facts does not call the action gate again or grant control.

If Resume admits a new browser context for a root that had not yet acquired one, it records the actual context admission under that owner operation. It does not invent native reacquisition of the previous task. The admission event is retained before the later page checks can fail.

The generic native handback API retains its existing result and error behavior. A native `finished` event specifically means that native reacquisition returned; it is not a successful authentication claim or a research completion result. Parent workflow events are currently emitted by the research owner; unrelated workflows cannot be inferred to have resumed merely from a native event.

Each sign-in window now receives a fresh native instance ID. Its open/close records and all observations taken while that exact child is current carry the same ID. Closing the window retires the ID with its delegate identity. Late child callbacks cannot become observations of a replacement window. A close event creates neither a native handback completion nor a workflow resume.

Attempts, their terminal outcomes, observations and control events receive a shared monotonically increasing order within the retained history. This orders recorded evidence without treating skipped activity as absent. The existing attempt and observation bounds remain 64 and 512; control history is capped at 128 records with a separate overflow marker. The ordinal counter advances only for those bounded records, including at most 64 terminal outcomes. Snapshot identity uses version 3 and advances for control changes or the first control-history overflow.

## Prepared coverage and allowed checks

Four new methods in [SourcePolicyTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSourcePolicyTests.swift) are authored and unrun:

- A complete research Pause/resume links the accepted parent operation to native reacquisition and retains the order of their distinct events, without another navigation.
- A password control appears on the same document during Pause. Native handback can finish, but subsequent authentication detection must leave the owner paused and record workflow failure under the same operation, with no workflow-success event.
- Foreign browser/ownership bindings and attempts to write a native phase through the workflow-only recording interface are rejected without changing current control events.
- Repeated blank-session handback fills the bounded control history, then retains the first records and an explicit overflow gap while preserving the existing unused session. The fixture performs no navigation or model work when eventually run.

Five existing scenarios gain assertions: shared native record ordering, native blank handback with both gate failure and success, closing an unfinished sign-in window, [popup lifecycle/explicit handback](../../../host-mac/RemoteDesktopHostTests/ComputerUseOwnedBrowserTests.swift), and [new-context admission during Resume](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserAdmissionTests.swift). The popup case binds its observations to the exact window's open/close interval.

Five changed Swift files passed `swiftc -frontend -parse`. The added authentication-change fixture passed `node --check`; it was not executed. Source inventories select 1620 default / 937 focused methods, four additions each and no removed or renamed identifiers. These are syntax and source-inventory checks, not compilation or passing assertions. No app/browser execution, inference, SSH retry, push or installed-app replacement occurred.

## Remaining repair order

Source follow-up: [policy installation history and reading freshness](BROWSER_NAVIGATION_HISTORY_READING_REVIEW.md) now bind diagnostic assessments to frozen native history and invalidate current use after later recorded or overflow activity. They still do not certify complete route compliance.

1. Reconcile ordered control events, native observation episodes, dispatches and owner-confirmed visits into a source/goal-bound history assessment. Treat unmatched operations, unknown attribution, claim discontinuities, unrecorded workflow scopes and all overflow markers explicitly.
2. Qualify callback ordering and coverage on supported macOS/WebKit versions. The ordering of retained records does not establish complete platform coverage or strengthen a slot correlation into an exact navigation identity.
3. Bind qualified history to current and retained readings and final answer admission. A later violating or unknown event must invalidate earlier eligibility. The [navigation-source completion gate](BROWSER_NAVIGATION_SOURCE_COMPLETION_GATE_REVIEW.md) remains active; this patch does not yet issue a compliance certificate.
4. Continue source-policy/criterion replacement, account/document/form recovery, semantic/model qualification and the broader [repair checklist](../../../TODO.md). Real-site scenarios and resource measurements remain deferred to explicit execution permission.
