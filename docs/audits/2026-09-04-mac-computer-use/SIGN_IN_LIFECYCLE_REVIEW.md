# Sign-in child creation and closure ownership

Source repair, 2026-09-10, following `822a399` and the [browser callback review](BROWSER_CALLBACK_CONTINUATION_REVIEW.md). This repairs the sign-in child boundary. Parent-browser Stop/Close and WebContent termination remain separate unfinished work. Native, test and model execution remains deferred.

## First-principles findings

Creating or destroying a native child window is a sequence of effects, not one atomic state change. After a native call or observable publication, code cannot assume that the current child, parent or control owner is still the one it started with. Cleanup should operate on retained old objects; continuation should require the original owner.

The sign-in factory in [ComputerUseOwnedBrowser](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) previously registered a child and published its site and status before installing observation and presentation. A subscriber could close that child or replace the control owner during publication. The old factory then continued, potentially attaching observation or a window for a retired child and returning it to WebKit for initial navigation.

Closure had the inverse ordering problem. It cleared the child identity, then stopped the child and repeatedly read the mutable `signInWindow` property to close and remove content. A reentrant replacement could make those later reads address another window. Site-clear publication could also stop or replace the parent, after which old closure still published handback guidance and focused the current parent window.

A valid sign-in lifetime is broader than the parent's current document. Parent navigation is normal during authentication, and an early Resume briefly changes the task's phase before the open child rejects handback. Binding continued child setup to a frozen parent document or requiring the gate to stay closed would break those flows.

## Source changes

Before constructing a child, the factory retains the parent session and ownership epoch. After construction, it rechecks the same parent, task and control owner and current popup admission before registering anything. It continues to use WebKit's supplied configuration and initial load, preserving the opener and shared native session behavior.

Once registered, setup retains the exact child, child instance ID, parent view/session/ownership and control owner. It rechecks them after site and detail publication, after observation creation, before attaching the native window and after presentation. Continued setup uses the existing same-owner `canNavigateSignInWindow` rule, so an early Resume does not silently discard an unfinished login. It does not bind that child to the parent's document generation or source policy.

An abandoned setup returns no child. It closes only its exact still-registered child; it cannot close a replacement. URL observation is created into a local value and assigned only after revalidation, preventing old setup from replacing a successor's observation token. An uninstalled native popup is cleaned up through its captured object.

Closure now captures the old child, popup, parent and parent window, then detaches all child identity/window fields before native cleanup. It stops and closes only those captured old objects. After cleanup it requires the retained parent state and control owner before clearing site presentation, checks again before handback guidance and checks the exact parent window before restoring focus. A reentrant replacement therefore owns its own subsequent status and focus decisions. Closing the child still does not assert successful authentication or automatically resume AI.

## Prepared cases and source checks

Three methods in [ComputerUseOwnedBrowserTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseOwnedBrowserTests.swift) are authored and **unrun**:

1. Close the child or replace its control owner during site/detail creation publication. Require an abandoned `window.open` result, no provider load, no later setup status after site interruption, and preservation of the parent document. The fixture records the page's observed `window.open` result; that native behavior still needs execution to qualify.
2. During closure's site-clear publication, Stop, Close, reclaim the parent, or replace only its control owner. Require preservation of the replacement's status/binding and a subsequent independent navigation without old cleanup affecting it.
3. Publish an early working/Resume phase under the same owner during site/detail creation. Require the child to continue loading while it still blocks AI ownership and explicit handback; closing it retains the original parent session and document.

These use existing loopback HTTP fixtures and real WebKit when executed later. The new cases are headless and do not prove actual NSWindow ordering, focus restoration, provider authentication or human input. The existing opt-in `ComputerUseOwnedBrowserVisibleAcceptanceTests.testSignedHostOwnsVisibleSignInWindowAndClosingItPreservesThePausedParent` remains outside the deterministic inventory; it was not run or enabled.

Expected names derive from HEAD plus the three reviewed new methods. The [default host inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects 1998 and [focused browser control](browser-control-state-inventory.json) selects 1315. A [bounded sign-in inventory](sign-in-lifecycle-inventory.json) selects nine: the three new cases and six existing opener/session, popup admission, owner retirement, explicit-handback, manager and source-policy cases. Client-core and pause-acknowledgement inventories remain 113 and 110. All five inventories match source identifiers. Both changed Swift files pass `swiftc -frontend -parse`; whitespace checks are clean. Syntax and identifier checks are not typechecking or executed assertions.

No build, typecheck, assertion/test execution, app launch, native capture, CUA interaction, model run or SSH retry occurred. The installed app and deferred performance stash remain untouched.

Local documentation validation finds 244 Markdown files / 2071 local targets / zero broken paths. The effective `.git/hooks` directory has zero executable non-sample hooks.

## Remaining repair and qualification list

1. Repair parent Stop/Close as complete lifecycle operations. `stop` calls child closure and pending-load failure before clearing shared task state; `close` calls Stop before reading current window/browser fields for release. A reentrant new owner must not be erased or have its window released by old cleanup. Retain exact native objects, separate logical retirement from external effects, and preserve pending DOM completion joins. A scope check that merely abandons a valid Stop whenever the same task changes pages is insufficient.
2. Repair WebContent termination and native `windowWillClose` continuations. They call child/failure/control callbacks and then continue changing global state. Distinguish the parent lifecycle from a changed page, and explicitly define how nested Close/Stop and replacement are handled. The child repair does not protect those outer callers automatically.
3. Qualify actual native construction, observation, popup presentation and close ordering, including parent navigation, early Resume, new provider windows, control-owner changes and focus changes while native methods run. Verify exact opener/postMessage/session behavior without supplying AI with credentials.
4. Review observable setter completion itself. Checks stop later writes but cannot undo a setter already publishing when a nested callback changes state. A retired creation can leave an old projected site value until the owning UI state replaces it; the child identity and native dispatch must remain retired regardless. General coherent status publication remains open.
5. Continue stale-at-entry delegate correlation, concurrent direct-input takeover and already-dispatched mutating-script work. Closing one native child is not a general proof that every earlier browser/native effect has ceased.
6. After readiness and explicit permission, qualify actual account login and retained-task Resume, then complete natural-language travel, concert and movie workflows against independently checked live results. Alternative-model adaptation remains available for measured need; 8 GB/thermal qualification follows correctness work.
