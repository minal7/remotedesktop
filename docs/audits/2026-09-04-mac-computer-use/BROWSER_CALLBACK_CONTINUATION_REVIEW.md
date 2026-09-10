# Browser callback continuation and completion status

Source repair, 2026-09-10, following `bafa1fb` and the [navigation admission review](BROWSER_NAVIGATION_ADMISSION_REVIEW.md). Native, test and model execution remains deferred.

## First-principles findings

A native callback does not own every browser state it can reach later. Returning a policy decision invokes external code; publishing observable status can synchronously invoke a subscriber. After either boundary, the browser or task may have been stopped, replaced or taken over. Cleanup must retain the operation it originally addressed, and current status must still belong to that owner.

The action, response and history policy delegates in [ComputerUseOwnedBrowser](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) previously had rejection branches that called a decision handler, then looked up the current pending operation or retired current observations. A handler that reenters could move those mutable slots to a successor. Some blocked-source branches also published a status before reading the pending slot for cleanup. A failed sign-in status could close or replace its window before the subsequent decision was recorded.

The completion delegates had a related status problem. They installed a historical navigation receipt or observed page, published its site and then unconditionally wrote “Page opened” or a page-readiness message. A subscriber stopping or replacing the browser during site publication could therefore be followed by an old callback announcing readiness in the new state. The waiting task's later ownership check did not prevent that intermediate publication.

## Source changes

The browser now captures a private callback scope containing the native view and parent, main/sign-in role, task, session and ownership/takeover epochs, document/location generations, pending and observed operation IDs, observed page IDs, sign-in instance and source policy. This is a snapshot of the current entry context, not an attribution of the native event's origin. It adds no model work, network request, control-gate query or persistent schema.

Action, response and history decision helpers verify that scope before recording the decision in current history and delivering it. A retired context receives a cancellation decision, without recording an old event against a successor. The native decision handler is still called once. Denial continuations recheck scope after the handler returns. They address the captured pending UUID, and observation retirement happens only while the captured context remains current. Blocked-source paths no longer publish a preliminary message and then discover which pending operation to fail; retirement owns its final error publication, or an idle denial publishes its explanation last.

Completed-navigation and observed-page callbacks capture scope after retaining their native fact and before publishing the site. They recheck it before publishing current readiness. The completed-navigation continuation is resumed through `defer`, including when publication retires the scope, so the waiter cannot be stranded by an early return. Its existing navigation-admission checks reject an obsolete current result. A confirmed native receipt remains historical evidence, and no lost current status authorizes a retry.

## Prepared cases and source checks

Three methods in [ComputerUseOwnedBrowserTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseOwnedBrowserTests.swift) are authored and **unrun**:

1. Stop, reclaim the same task, or close the browser from completed-page site publication. Require the later old callback to preserve the stopped/reclaimed status, release its waiter and retain the captured native completion fact.
2. Take Control at completed-page publication, with admission staying closed or immediately reopening. Reject the old current return and suppress its completion status while retaining the session and actual receipt.
3. Finish a controlled navigation during user control, then Stop or Close from its accepted-page publication. Require that the old callback cannot publish page readiness afterward. The fixture finds the accepted observation in native history instead of assuming the timing of WebKit's separate `isLoading` flag; it temporarily opens its local fixture gate only for that history read.

These cases use existing loopback HTTP fixtures, synchronous Combine subscribers and real WebKit when eventually executed. Controlled page scripts simulate navigation during user control; no credentials or human input are supplied. The new methods cover completion-publication reentrancy. They do **not** inject reentrancy inside WebKit's decision-handler implementation; the new denial guards have source-review evidence and still need that native qualification.

Expected names derive from HEAD plus the three reviewed new methods. The [default host inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects 1995 and [focused browser control](browser-control-state-inventory.json) selects 1312. A [bounded callback inventory](browser-callback-continuation-inventory.json) selects 28 methods: the previous 19 admission cases, the three new completion cases and six existing policy, redirect, history and sign-in cases. Client-core and pause-acknowledgement inventories remain 113 and 110. All five inventories match source identifiers. Both changed Swift files pass `swiftc -frontend -parse`; whitespace checks are clean. These checks do not establish type correctness or executed behavior.

No build, typecheck, assertion/test execution, app launch, native capture, CUA interaction, model run or SSH retry occurred. The installed app and deferred performance stash remain untouched.

Local documentation validation finds 243 Markdown files / 2063 local targets / zero broken paths. The effective `.git/hooks` directory has zero executable non-sample hooks.

## Remaining repair and qualification list

1. Review WebContent termination and browser/sign-in teardown across publication and native window callbacks. The current termination path can call `closeSignInWindow` or `failPending`, then continue clearing current page state. That continuation needs its own retained lifetime and completion policy. The subsequent [sign-in child repair](SIGN_IN_LIFECYCLE_REVIEW.md) protects child creation/closure; its outer parent Stop/Close and termination callers still require repair.
2. Qualify reentrant action/response/history decision handlers, including source denial and sign-in replacement, and verify exactly-once native completion. Add a controlled native driver seam only if needed to reproduce the actual lifecycle; value-only fixtures cannot establish WebKit behavior.
3. Establish correlation for callbacks that are already stale when they enter the delegate. Action and response policy callbacks lack an exact `WKNavigation`; this entry snapshot cannot prove which load originated them. A matching URL or current slot is insufficient evidence. Late responses and process callbacks must not be treated as fully resolved by this patch.
4. Qualify native load/history/stop ordering and concurrent direct-input takeover. Scope checks around synchronous callbacks do not make the gate read and native dispatch atomic, retract an already-dispatched script or prove page stability for the person's next edit.
5. Review broader observable state publication. The new check stops a subsequent readiness assignment; it cannot undo a setter already publishing when a nested callback changes state. Real pending/paused/stopped presentation and focus require native validation.
6. After readiness and explicit permission, verify actual account login, retained-task Resume, transport interruptions and complete travel/concert/movie requests against live results. Natural-language correctness, alternative-model suitability and measured 8 GB/thermal behavior remain unqualified.
