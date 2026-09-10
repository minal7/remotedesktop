# Browser work already pending at Take Control

Source repair, 2026-09-10, following `2048a88`. Native, test and model execution remains deferred. This is a bounded cancellation-order repair, not qualification of real account login or complete website tasks.

## First-principles findings

Closing permission for the next action does not retract an action already sent to WebKit. Cancelling its Swift task also does not synchronously retire its native navigation. In [ComputerUseOwnedBrowser](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift), the navigation cancellation handler schedules cleanup on a later MainActor turn. Meanwhile, the pending AI navigation still occupies the browser. The navigation policy delegate can reject an incoming navigation because that pending operation has lost ownership, and its cleanup then stops loading the native view.

That stop is broader than an operation identifier. Apple's [`WKWebView.stopLoading()` contract](https://developer.apple.com/documentation/webkit/wkwebview/stoploading()) describes stopping resources for the current page; it does not accept a `WKNavigation` argument. Publishing an observable error before calling it therefore leaves room for a reentrant successor to be affected by old cleanup.

The old host Pause hook only paused a retained research owner. A direct URL workflow could have a pending native load without such an owner. Conversely, an unrelated retired research object can remain retained when a later URL task owns the browser. Neither the existence nor absence of that historical object is sufficient to identify the native work to retire. Accepted clarification answers add a further distinction: the current execution ID may differ from the original browser root, and a stale root command must not pause the answer's successor.

An already-dispatched DOM script has a different lifetime. WebKit does not provide a way here to recall that script. Rejecting its reply can prevent the task from treating the result as current, but cannot prove that the script has stopped affecting the page. Releasing its native slot early would allow overlapping work.

## Source changes

The [host manager](../../../host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift) now calls `pauseOwnedBrowserForUserControl` after closing action admission and before publishing paused activity. The [navigation task](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserNavigationTask.swift) pauses a matching research execution, retains its browser-session requirement across that call and rechecks the exact research object, execution ID and browser binding before native cleanup. A stale original root remains rejected after an answer takes ownership. Other task IDs reach the browser's own exact-owner check, allowing a current URL task to retire its load despite an unrelated historical research object.

`prepareForUserControl` requires the exact current task and closed action admission. It synchronously fails the captured explicit AI navigation, cancelling its timeout/restoration and recording ownership loss. The later task-cancellation handler retains the old operation UUID and cannot retire a new pending operation. Native failure cleanup calls `stopLoading()` on the captured view before publishing error detail; publication additionally requires the same view, ownership epoch, retired document generation and task, with no replacement pending navigation.

The preparation then rechecks the browser/session/ownership binding and closed admission before withdrawing a captured DOM continuation. Its native slot stays occupied until the original callback or browser close releases it. The caller can receive the error before that callback returns; existing explicit completion waits/joins remain responsible for waiting. This change does not make ordinary `callDOM` error return a native completion witness.

The hook does not blanket-stop every browser load. It preserves an observed page navigation during user control, the retained browser session and the provider sign-in window. Repeating preparation with no explicit AI work pending leaves those paths alone. Explicit Resume and existing native handback checks still govern page adoption; observing a page is not an automation navigation receipt.

## Prepared cases and source checks

Five methods in [ComputerUseOwnedBrowserTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseOwnedBrowserTests.swift) are authored and **unrun**:

1. Cancel a held AI navigation, perform host-tool takeover synchronously before its queued cancellation handler, then admit a successor load. Check that old cleanup/response cannot create an old receipt or retire the successor.
2. Retain an unrelated retired research object while a new URL task owns a held load. Check that takeover reaches the current native owner without replacing the historical research object.
3. Hold a controlled page-script navigation until after takeover, repeat takeover while that observed load is pending, then explicitly reacquire its page. Check retained session identity and absence of an invented automation receipt.
4. Reject takeover preparation for a foreign task and while action admission remains open, leaving the current load intact.
5. Withdraw a page-snapshot reply at its dispatch boundary, reopen admission, wait for the native callback, then obtain and validate fresh evidence. The reopened gate cannot revive the withdrawn reply.

These cases use the existing loopback HTTP fixture and real WebKit when eventually executed. The third case simulates navigation during user control with a controlled site script; it does not inject human input or test credentials. Preparing the historical research object does not invoke its fixture planners. Existing [clarification transport](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserClarificationTransportTests.swift) and [research task](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchTaskTests.swift) cases use the renamed host hook.

Expected identifiers derive from HEAD plus five explicitly reviewed new names. [Default host](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects 1986 and [focused browser control](browser-control-state-inventory.json) selects 1303. A [bounded takeover inventory](browser-takeover-retirement-inventory.json) selects the five new cases and five existing cancellation, session, clarification and manager-handback cases. Client-core and pause-acknowledgement inventories remain 113 and 110. All five inventories match source identifiers. Six changed Swift files pass `swiftc -frontend -parse`; this establishes syntax only, not type correctness or runtime behavior. Whitespace checks are clean.

No build, typecheck, assertion/test execution, app launch, native capture, CUA interaction, model run or SSH retry occurred. The installed app and deferred performance stash remain untouched.

Local documentation validation finds 241 Markdown files / 2047 local targets / zero broken paths. The effective `.git/hooks` directory has zero executable non-sample hooks. The workspace volume reports 83 GiB available; no generated-file cleanup was needed.

## Remaining repair and qualification list

1. Review navigation admission across observable publication before `pending` is installed. A Take Control callback during “Opening page” publication must not be followed by a newly dispatched load. This patch retires work already pending; it does not yet establish the entire pre-dispatch boundary.
2. Qualify actual native callback ordering around `stopLoading`, including reentrant native callbacks and late responses. Action/response policy callbacks do not carry the same `WKNavigation` identity as completion callbacks; source-level UUID cleanup alone does not prove all stale delegate events are harmless.
3. Establish how already-dispatched mutating scripts settle before the person edits a form. Withdrawing a continuation and retaining its native slot do not undo an effect, protect login focus, or prove that the page has stopped changing. Preserve uncertain effect records and prevent automatic replay.
4. Qualify the interval between the input posting lock closing admission and the MainActor performing this preparation. A received Pause acknowledgement does not prove that every earlier effect has ceased. External-app activation, accessibility injection and other native effects need their own ownership analysis.
5. After explicit permission, run the bounded native cases, then actual Take Control, provider login, rejected/early Resume and accepted handback while retaining the original task. Include cancellation-ignoring work, lost acknowledgements, reconnect and browser replacement.
6. Retain the real travel/concert/movie scenarios and independently verify their results after readiness and explicit permission. Natural-language correctness, visible-screen freshness, alternate-model suitability and measured 8 GB/thermal qualification remain open. Model pruning or distillation is not a substitute for fixing these control boundaries.
