# Reacquire the browser page after user-controlled sign-in

Parent source: `3f6a6c2`. Status: source repair and prepared regressions only. No build, XCTest run, inference, app launch, computer-use activity, real account login or public-website test occurred. Performance optimization and live travel/concert/movie scenarios remain deferred.

## First-principles requirement

Handing control to the person must preserve the browser session and original task while closing automation. Returning control permits fresh observation and continuation; it does not prove that authentication succeeded, that the account is correct, or that an AI navigation step executed.

The host already pauses `.userInterventionRequired` without completing the task and requires an authenticated Resume. Resume waits for the preceding executor to return before admitting its successor. However, the owned browser invalidated its current document on a manual login redirect and never recorded the resulting page. `acquireCurrentDocument` therefore had nothing it could safely reacquire.

## Source change

- Added an independent record for a main-frame navigation that starts and finishes while the action gate is closed. It binds the exact WebKit navigation, browser generation, final successful HTTP response URL and current page URL. It does not read a form, password, code, cookie or account value during user control.
- A finished page remains unavailable to automation until explicit host handback. Merely setting the action gate to allow actions does not publish it as the current document. Failed loads, page changes made while automation is active, outstanding navigation/DOM work, changed locations and stale generations cannot be adopted.
- The host's authenticated Resume path calls the browser handback operation after joining the previous execution and admitting the current token. If the browser is still loading or cannot provide a valid observed page, the host preserves the original context and returns to the existing nonterminal intervention state. The successor executor does not run. Approved-action recovery still occurs before this browser operation; historical confirmed/uncertain effects do not depend on browser readiness.
- A successful handback produces a fresh document whose source is explicitly `userControlObservation`. It has a distinct observation ID and remains absent from the navigation-receipt store. The location is observed data, not an assertion that the requested URL was navigated by automation. Transferring that current document to a later task preserves this source.
- Old navigation receipts remain historical evidence for their original operations, but cannot validate as the newly observed current document. Handback does not issue a network request or restart the original navigation. The same WebKit instance and its existing nonpersistent data store remain in use.
- Loading, stop, close, process termination and observed location changes invalidate pending observations. Delegate callbacks from another/released WebKit view cannot alter the current browser. Navigation generations protect against same-URL reloads. Same-document script/history changes still require fresh DOM/goal verification; the asynchronous URL observer is not a complete history-event journal.

An unchanged valid page requires no replacement navigation receipt. If the owned browser is unrelated to the resumed task and is not the frontmost window, handback leaves it alone. Closing/releasing the browser still destroys its private in-memory context; this patch does not add persistent account storage or import another browser's cookies.

## Prepared regression coverage

Three new methods are registered:

1. Controlled page changes to both a different URL and the same URL while the gate is closed. Reopening the gate alone cannot expose the page; explicit handback supplies a fresh observation, preserves the old receipt as historical evidence, creates no new receipt or network request, preserves source through a later task transfer, permits a fresh supported-field observation and clears state on close. The different-page fixture checks a retained sessionStorage marker.
2. An automatic page change while automation remains active and an HTTP 404 during user control. Neither can be adopted as a user-control observation.
3. A host-manager/recording-executor flow through the existing authenticated control envelopes. The first executor opens a loopback fixture and requests user intervention. Resume while the next page is held must pause again without another executor call. A higher Resume revision after the page settles reaches the second call with the same task ID and trusted request, a new observed document, retained sessionStorage and no repeated login/account navigation.

The fixture simulates page navigation through controlled local script/HTTP responses. It does not type credentials, prove authentication detection or qualify an actual provider. The original task wording mentions travel, but the scripted executor only verifies the fixture page; it is not a travel-search acceptance test.

Source inventories match **565 default** and **22 focused** method identifiers; whitespace checks pass. See [the focused inventory](browser-login-handback-inventory.json). The existing owned-browser methods and selected intervention, authorization-loss, disconnect and approved-action recovery cases accompany the new cases. No changed Swift source has been compiled or executed for this repair.

## Remaining work toward the user's browsing/login requirement

1. Compile full browsing goals with navigation, search, dates/locations, result extraction and source-backed outcome predicates. Keep account/page observations separate from receipts for AI actions and require every remaining goal obligation. The current explicit URL route and supported forms do not implement general travel/concert/movie searches.
2. Reconcile/replan remaining steps after handback. Retained form/visual targets may belong to the pre-login document. They must fail stale checks, then a reviewed continuation must bind fresh targets without discarding attempted effects or replaying completed work. This patch enables fresh document acquisition, not arbitrary contract rebasing.
3. Support reviewed popup/provider login flows and return to the intended task page. The current browser still cancels targetless popup navigations. Preserve visible window ownership and session continuity; handle provider refusal of embedded browsers explicitly.
4. Complete local and phone handoff controls and their presentation. The phone's existing nonterminal intervention/Resume path is wired here. The owned browser's local Stop button currently calls browser stop rather than the host task's lifecycle control; make local takeover/handback/Stop reflect the same authoritative task state before qualifying those controls.
5. Verify authentication handling, MFA/passkeys/CAPTCHA, account identity and session expiration without exposing password/OTP fields or authentication tokens to model observations and task logs. Resume is authorization to continue, not proof of successful sign-in. This patch reads only navigation metadata while control is handed over.
6. Qualify cancellation during DOM callbacks, repeated handback, new-task replacement, authorization loss, disconnect/reconnect, close, WebContent termination and restart across host and phone. The added source tests include selected cases, not this whole matrix.
7. Once the user authorizes execution, compile and run the focused fixtures first, then measure readiness/resources and seek the separately required permission for bounded real-website/account scenarios. No 8 GB, thermal, account or public-web qualification is established.
