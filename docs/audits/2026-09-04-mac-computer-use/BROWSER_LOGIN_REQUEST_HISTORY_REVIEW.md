# History of manual sign-in requests

Source repair; execution pending. This follows the [observed login-entry handoff](BROWSER_LOGIN_ENTRY_HANDOFF_REVIEW.md). No app, browser, model, account login or test execution occurred.

## First-principles defect

Requesting sign-in, returning control and being authenticated are different facts. The previous repair could request manual login and pause the original task. After handback, however, the action planner had no structured record that it had requested login or that the person had returned control. A common sign-in header could therefore motivate the same request again without reconsidering the user's intervening work.

The existing host Resume flow already checks the owned browser/session and asks the research owner to reacquire the page. Active credential fields can reject early handback. These checks do not establish account identity or authentication success; the missing information was the history of the request and control return.

## Source changes

The [research owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) records a login request only after the latest native page observation has been revalidated, cancellation/ownership checked, and the task paused. Its record retains the original goal, bounded public entry label/kind, native document identity and session binding. It retains no entry control/link reference, destination URL, credential value or action capability.

A successful explicit owner Resume marks only the latest pending request as having returned control. This update occurs after native session/page checks, child-task completion, cancellation checks and the current control-epoch check. A failed or cancelled Resume leaves the record pending. The return must match the original native session binding and continue the exact goal/accepted-answer ancestry. Returning again cannot acknowledge an already-returned record a second time.

[Action context](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) version 27 includes `login_handoff_history` even when the new page has no sign-in entry. Each row identifies the historical entry label, whether control returned, whether the document identity is unchanged, and whether the request/return used the current goal revision. `authentication_verified` is always false. Native document/session identities and binding digests remain host-side; old public entry aliases are not carried into the history.

The input requires ordered records in the same session and goal ancestry; only the last request may still await return. A pending request withholds another automated login request. History also keeps the action planner's no-decision shortcut from skipping this information on a later page. Instructions require fresh reasoning and explicitly reject treating a remaining optional sign-in link, a return of control, or an earlier request as proof that another login is necessary.

The owner bounds the history at 32 requests per research task. At that limit, the context withholds further automated login requests and explains the limit without introducing another login mechanism. The person's visible task controls remain available. This bound does not establish task completion. Owner retirement clears the history.

## Prepared coverage and permitted checks

Three new [action-planner methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserActionPlannerTests.swift) are authored and unrun:

- Same-page handback records returned control while the sign-in link remains. The context still denies authentication verification, keeps native identities/private URL data out of the prompt, permits ordinary research planning and rejects reuse of the old request. Retirement clears the history.
- Cancellation during the handback page observation cannot mark the request returned; a later explicit successful handback updates that same record once.
- Foreign session bindings, foreign goal roots, unordered history, overlapping pending requests and repeated acknowledgments are rejected. The bounded history withholds further login aliases while preserving a planning decision.

The existing [driver sign-in case](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchDriverTests.swift) now checks pending history before and after an early authentication failure, returned history after a successful fixture handback, and the post-navigation action context's explicit lack of authentication proof.

Four changed Swift files pass parse-only checks. Maintained default/focused inventories select 1706 / 1023 methods, with three additions and no removals. These are source checks only; no typecheck, build, assertion, native fixture or model outcome is established.

## Remaining work

This is live-owner request history, not durable recovery after process replacement or proof that the handoff message was delivered to the person. The host retains its existing durable control lifecycle. Full installed host/phone/provider qualification remains deferred.

Old form, dropdown and selection obligations remain bound to their original native objects and documents. A login redirect can invalidate those objects. Their verified replacement or release requires explicit native effect/obligation reconciliation; this history neither discards those duties nor permits replay of uncertain input. Continue that work without relaxing stale-target checks.

The model still decides whether account access is necessary. History can inform that decision but does not prove it correct, stop every repeated request, identify the account or establish successful sign-in. Complete provider/account predicates, result verification, unsupported login formats and durable goal/effect recovery through the [repair checklist](../../../TODO.md). Execution, resource measurement and real travel/concert/movie/account scenarios remain deferred to their authorized stage.
