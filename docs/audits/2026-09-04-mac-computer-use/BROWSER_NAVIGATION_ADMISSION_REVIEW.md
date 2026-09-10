# Navigation admission across takeover and observable callbacks

Source repair, 2026-09-10, following `47d54b9`. This continues the [pending browser takeover review](BROWSER_TAKEOVER_RETIREMENT_REVIEW.md). Native, test and model execution remains deferred.

## First-principles findings

An effect needs the same authority at dispatch that admitted its preparation. A matching task ID and an open Boolean gate are insufficient: a callback can stop and reclaim the same task, replace its browser, or pause and return control before the old call continues. The old call must retain the original lifetime, not acquire whichever lifetime happens to exist afterward.

In [ComputerUseOwnedBrowser](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift), `performNavigation` previously checked ownership around presentation and `willBeginEffect`, then published `displayedSite` and “Opening page…” before installing `pending`. A synchronous subscriber could call Take Control during either publication. The takeover hook found no pending navigation, and the original call subsequently installed a new one and invoked WebKit. Checking permission before publication did not protect the effect after publication.

The preparation checks also relied on the current task ID. Exact prerequisite-document validation protected some later workflow steps, but a first-page call without a prerequisite or explicit blank-session requirement could cross a same-task Stop/reclaim or browser replacement. A Pause followed by reopening admission could leave all those Boolean checks true.

A related completion path treated failure of the final DOM identity read as an optional lack of DOM support. If takeover withdrew that read, followed by reopening admission, the fallback could return the navigation result because the document still matched. A historical native completion may remain true, but that does not authorize the interrupted call to return a current result.

## Source changes

Navigation now captures the original ownership epoch, native view/session, document generation and a separate takeover epoch. The latter changes only when the current browser owner receives takeover preparation with action admission closed. It does not replace the browser's retained handback identity or document generation. A brief Pause therefore invalidates the old preparation even when the gate has reopened by the time a callback returns.

Preparation rechecks cancellation, exact owner/view/session/takeover scope, original generation, idle native slots, prerequisite document/presentation, initial-session requirement and source/history policy after presentation and after `willBeginEffect`. Existing source and prerequisite checks remain in place. A durable caller that already recorded an attempt still has to reconcile its own state; rejection here is not permission to repeat that attempt.

The pending record and its timeout are installed before the two observable status assignments. The call checks its exact pending UUID, scope, generation, slot state, current source policy and required presentation before publication, between the assignments and immediately before invoking WebKit. A reentrant Pause or Stop can retire the registered reservation; a removed reservation cannot be recreated by the old call. If only the action gate has closed and host preparation has not yet run, the post-publication check retires the reservation itself.

Each pending navigation distinguishes reservation from entering the native dispatch call. Failure of a reservation that never reached that call does not invoke the view-wide `stopLoading()`. Existing attempted-operation records remain conservative; the private flag is not exported as a no-effect proof and does not erase journal uncertainty. Once native dispatch starts, its return value is assigned only if the exact pending UUID still owns the slot. An old native return cannot be stored into a replacement operation.

The same captured owner/takeover scope is checked through the post-navigation focus wait and after the final DOM identity read, including its fallback. An interrupted call rejects the current result even if the gate is open again. Existing confirmed navigation receipts remain available as historical facts. This preserves reconciliation without inventing a retry or denying a native load that actually completed.

## Prepared cases and source checks

Six methods in [ComputerUseOwnedBrowserTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseOwnedBrowserTests.swift) are authored and **unrun**:

1. Take Control from either site or detail publication, with admission remaining closed or immediately reopening; also close only the gate to represent the interval before host preparation. Inspect retirement inside the takeover callback and prevent further old status publication where applicable.
2. Stop or close the browser from either publication, then prepare the same task ID again. Preserve the replacement binding and history across the old call's unwind, and allow a new operation to navigate.
3. Pause and reopen admission inside `willBeginEffect`. Reject the old preparation while preserving the untouched native session; a different subsequent operation remains possible.
4. Stop/reclaim or close/recreate the same task inside `willBeginEffect`, without a prerequisite document. Require the original lifetime even for that first-page call.
5. Cancel the running child task synchronously from site publication. Reject the old call before “Opening page…” or native load, then allow a separate operation.
6. Take Control during the final page-identity read after native navigation has finished. Reject the interrupted return, retain the actual receipt and wait for the already-dispatched DOM callback without reloading.

These fixtures use synchronous Combine subscribers and controlled loopback WebKit loads when executed later. A zero server request count alone cannot prove that no native API was invoked; callback-time retirement, publication ordering, replacement-history checks and the explicit source boundary are separate evidence. The fixtures do not exercise actual UI gestures, credentials, local models or real ticket websites.

Expected identifiers derive from HEAD plus the six reviewed new names. The [default host inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects 1992 and [focused browser control](browser-control-state-inventory.json) selects 1309. A [bounded navigation-admission inventory](browser-navigation-admission-inventory.json) selects 19: the six new methods, the previous ten takeover methods and three existing prerequisite, durable-reload and source-policy methods. Client-core and pause-acknowledgement inventories remain 113 and 110. All five inventories match source identifiers. Both changed Swift files pass `swiftc -frontend -parse`, and whitespace checks are clean. These are source checks, not typechecking or executed assertions.

No build, typecheck, assertion/test execution, app launch, native capture, CUA interaction, model run or SSH retry occurred. The installed app and deferred performance stash remain untouched.

Local documentation validation finds 242 Markdown files / 2055 local targets / zero broken paths. The effective `.git/hooks` directory has zero executable non-sample hooks.

## Remaining repair and qualification list

1. Qualify actual WebKit ordering during `load`, history restoration and `stopLoading`, including callbacks before native dispatch returns. The exact-UUID return check prevents a stale slot assignment; it does not prove that stopping inside a native call prevents every later effect of that call.
2. Review late action/response delegates, which lack exact `WKNavigation` correlation. A stale response must not be attributed to a successor or cause its load to be stopped. Also review status publication inside native delegate and browser teardown paths. This patch does not make every observable assignment atomic or prevent a setter already publishing from completing after a nested callback changes state. The subsequent [callback continuation repair](BROWSER_CALLBACK_CONTINUATION_REVIEW.md) binds post-handler cleanup and completion status to the callback's entry context; stale-at-entry correlation and teardown remain open.
3. Establish the full boundary between direct input closing the action gate and MainActor browser takeover. A read of the gate immediately before WebKit invocation is not a lock spanning a concurrent human-input event. Broader native focus, accessibility and external-app effects still need their own ownership analysis.
4. Complete the review of mutating DOM calls already dispatched during takeover. Withdrawing a reply and retaining its slot do not retract the script, prove page stability or protect the person's next edit. Preserve exact uncertain-effect records and explicit native joins.
5. After explicit permission, execute bounded native cases, then actual login and Resume with the retained original task. Verify the pending/confirmed UI, native focus, current-screen evidence, interrupted/replaced sessions and lost or delayed acknowledgements.
6. Qualify complete natural-language travel, concert and movie tasks using independently verified live results after readiness and permission. Alternative models and RTX 3080 adaptation remain available for a measured model failure; lightweight 8 GB and thermal qualification follows correctness work.
