# Browser process failure and retained task authority

Source repair, 2026-09-10, following `28618af` and the [parent Stop/Close review](BROWSER_PARENT_RETIREMENT_REVIEW.md). Execution remains deferred.

## First-principles findings

A terminated web-content process invalidates the page's current evidence. It does not mean the user cancelled the task, that a sent request never reached its server, or that an already-dispatched script had no effect. Task ownership, historical attempt facts and current page evidence therefore need separate treatment.

Apple describes [the termination delegate](https://developer.apple.com/documentation/webkit/wknavigationdelegate/webviewwebcontentprocessdidterminate(_:)) as notification about a web view's terminated content process. The installed `WKNavigationDelegate.h` states that narrow contract; it supplies a WKWebView, not a navigation identity, process-generation receipt or script-completion receipt. This repair does not infer any of those missing guarantees. The online documentation reader exposed only a JavaScript/Markdown notice, so the contract review used the installed SDK header.

The old [browser handler](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) closed the sign-in child through a helper that published an ordinary handback invitation, then published a failure status. Main-process failure also failed a pending load through another publishing helper before clearing current observations and document state. A subscriber could stop, close or replace the browser during either publication; later cleanup and status then applied to whatever occupied the shared fields. A DOM waiter was not withdrawn at the process-failure boundary.

A failure cannot simply call Stop: that would replace the failure with ownership loss, retire the original claim and change task recovery semantics. Nor can a child failure establish parent failure by assumption. Native cleanup must retain the original parent identity, collect any additional failure notification for that parent, and let an explicit user Stop/Close keep its distinct meaning.

## Source changes

Failure cleanup now captures the parent view, session, task and ownership epoch. Claim/action admission and ordinary navigation callbacks remain closed during its synchronous native cleanup. A child is logically detached before native teardown, without publishing the ordinary child-close invitation. When the parent fails, its pending navigation is detached with a failed outcome, page observations end with process termination, document/DOM identity is invalidated and its ordinary DOM waiter receives page-changed. The original claim, browser session, source policy, attempt records and historical receipts remain retained.

The old pending-navigation continuation resumes through `defer`, including when status publication admits a replacement. A dispatched DOM slot remains occupied until its actual callback or explicit browser release. Failure does not manufacture a completion join, erase uncertainty or authorize a retry. If that callback never arrives, Close remains necessary to release the old session's slot; this notification alone is not a native-quiescence proof.

The child and main view can report failure during the same native cleanup. A matching parent notification is recorded and coalesced into the current operation, then its page state is invalidated before publication. A duplicate child notification cannot recursively close a successor. Explicit nested Stop/Close still performs its retirement; the outer failure rechecks the original epoch and cannot restore the retired owner or overwrite its later status.

After captured cleanup, admission reopens. Child-site clearing, failure status and optional parent focus each require the retained post-invalidation callback context and control owner/task. A replacement admitted by publication remains current. Child-only failure preserves the original parent's document identity; actual shared-process parent failure requires its own notification. No Resume/Stop command or login-success assertion is synthesized.

## Prepared cases and source checks

Four methods are authored in [the existing visible acceptance class](../../../host-mac/RemoteDesktopHostTests/ComputerUseOwnedBrowserTests.swift), all **unrun**:

1. Inject termination while a loopback page response is held. At failure publication, require the original task/session, failed attempt and absence of claim retirement. Replace the session, then require the old navigation to fail without clearing the replacement or replaying the original request.
2. Inject termination after a page-snapshot dispatch. Require withdrawal of the current result, busy admission until the original callback joins, invalidated current evidence, retained historical navigation and a later independent request under the same task.
3. Inject parent versus child failure during a paused sign-in, with and without replacement from child-clear publication. Require captured popup cleanup, no ordinary-close invitation, preserved task controls and either retained parent evidence or parent invalidation as appropriate. Detached old views must not report against a new session.
4. Deliver parent failure from the child's actual close notification. Require coalesced history and invalidation, busy admission during cleanup, preservation of a nested explicit Stop/Close, and eventual admission for a new task.

The fixture helper finds the native WKWebView in the visible window's view hierarchy. These methods retain the existing `RUN_OWNED_BROWSER_VISIBLE_ACCEPTANCE` gate and remain outside default/focused selectors. They inject the delegate event; they do not terminate a WebContent process. Even future passing executions would qualify only that controlled event path, not real crash delivery, complete login or natural-language success.

The [new visible failure inventory](browser-process-failure-visible-inventory.json) selects the four reviewed names plus the two existing parent native-retirement cases, derived from HEAD and explicit names. Seven inventories match source: default host 2001, focused browser 1318, bounded parent 14, parent visible 2, failure visible 6, client core 113 and pause acknowledgement 110. Both changed Swift files pass parse-only checks; whitespace checks are clean. The documentation scan checked 246 Markdown files and 2087 local targets without missing files; anchors were not checked. The effective Git hooks directory contains no executable non-sample hooks. No typecheck, build, tests/assertions, app launch, native capture/CUA, model run or SSH retry occurred. The installed app and performance stash remain untouched.

## Remaining repair and qualification list

1. Attribute callbacks already stale on entry, especially process/URL/response callbacks from the same retained WKWebView after Stop or a claim change. The new barrier protects cleanup continuation; it does not supply the native process/navigation correlation missing from those delegate signatures.
2. Check coherent observable presentation. Rechecks protect later assignments, but cannot undo a setter already publishing when a subscriber changes state. Window focus calls and outer AppKit close completion also need actual native evidence.
3. Qualify real process death and script callback order after permission: failure before/after dispatch, shared child/opener failure, lost callbacks, explicit Close, same-task pause/Resume, preserved source/attempt history and uncertain mutations. Do not interpret injected notification or callback arrival as evidence that a network effect was undone.
4. Qualify these opt-in cases together with actual host control persistence and login handback. The retained task must reacquire fresh page evidence; it must neither report login success from child closure nor silently replay its prior operation.
5. Finish the broader correctness list before live travel/concert/movie tasks. Their model planning and independently checked live results remain unqualified. Alternate-model work and 8 GB/thermal measurements stay deferred to the authorized later stage.
