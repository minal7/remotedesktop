# Login handback after a history or fragment change

Parent source: `e4845fd`. This repair changes source and prepares regressions only. No build, XCTest execution, model run, app launch, computer-use activity or account login occurred. Performance work remains deferred and the user's execution pause remains in force.

## First-principles problem

A login flow can replace its form and call `history.replaceState`, `history.pushState` or change the fragment without loading a new Document. The browser's existing URL observer invalidated the prior reference, but only a successful full navigation could leave an observation eligible for explicit handback. The task therefore reached a page that it could not reacquire, even if authentication had already stopped the native route before planning or input.

The old URL observer also queued every update to a later MainActor task. A URL change observed during automation could be processed after Pause, and a rapid A → B → A sequence could disappear behind the final current-URL comparison. A URL string alone cannot prove loaded-document continuity or the authority under which its change was observed.

Upstream WebKit handles same-document navigation separately: it updates the page-load URL and commits the change, and its Cocoa navigation client has a distinct private same-document callback. The page-load-state method does not change the loading state. This supports using public URL observation plus independent document evidence; the app does not call a private delegate API. Sources: [WebPageProxy.cpp](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebPageProxy.cpp), [PageLoadState.cpp](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/PageLoadState.cpp), [NavigationState.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Cocoa/NavigationState.mm). This upstream source review is not proof of the installed macOS WebKit's runtime behavior.

## Document evidence without credential collection

The existing fixed script in the isolated content world now creates a random `pageID` for its captured Document. A dedicated `pageIdentity` command returns only that nonce and a readiness status. It runs before form discovery, credential matching or mutation-record processing. It reads no field value, label, URL, cookie, token or account identity and performs no DOM input.

This nonce is independent of the existing text-binding document ID. Replacing the document element can invalidate all old field bindings while retaining the identity of the loaded Document. A new Document gets a new nonce. The existing native field membership, exact values, root and target checks still govern every form action.

The bridge uses the existing bounded `callAsyncJavaScript` mechanism and DOM-operation slot. Its validation closure now permits either the established exact document check or the narrowly scoped handback-observation check. The host uses a fixed command and validates the result shape and nonce; neither model output nor page text supplies JavaScript. Apple's [callAsyncJavaScript documentation](https://developer.apple.com/documentation/webkit/wkwebview/callasyncjavascript(_:arguments:in:in:completionhandler:)) describes this public content-world invocation API.

After a successful owned navigation, the browser attempts this value-free identity capture before returning. Successful full-page handback also captures it when available. DOM availability is not required to truthfully report opening a non-DOM resource: identity failure leaves no history-continuity proof, while ordinary navigation still requires its existing successful response/current-document/presentation checks. The attempt uses the existing DOM deadline and cancellation ownership; it adds no model inference or recurring polling worker.

## Observing and accepting a history change

The URL callback processes an expected main-thread notification synchronously through `MainActor.assumeIsolated`. It observes the gate at that callback, preserves each delivered URL transition and confirms the originating WebKit view. Unexpected off-main notifications are sent to MainActor only to invalidate state; they cannot create a handback candidate. These are application-level notification-order safeguards, not a complete history-event journal inside WebKit.

Every accepted location change invalidates the old document reference and advances generation. It creates a possible same-document handback observation only with an existing captured identity, a closed AI gate, an owning task, no pending navigation, no user navigation in progress, a nonloading view and a valid web URL. Changes during automation discard continuity proof so a later Pause/Resume cannot promote them. Repeated changes during the same user-control period retain the identity but replace the observation ID and location.

Explicit handback is now asynchronous. Before publishing a fresh document it reads identity again and checks the same browser, task owner, observation ID, generation, full current URL, nonloading state and open handback gate. A same-document candidate must match the earlier identity. The resulting document remains `userControlObservation`, with no navigation receipt for its observation ID. Historical AI navigation receipts remain historical; they do not validate as the new current document. Fresh form targets include the new browser generation.

The host waits for this operation after joining the preceding executor, then checks cancellation and its execution token again before calling the successor executor. A cancelled read keeps its DOM slot until its actual callback; Stop/close invalidate the observation and identity. The local guidance now names the actual `Let AI continue` button.

## Prepared regressions

Four browser methods and one host/native method are added:

1. Push state, replace state, hash changes and A → B → A changes while the gate is closed replace the form without a network navigation. Explicit handback gets fresh targets, old references fail, a new field edit is independently observed once and no AI navigation receipt is invented.
2. History changes while automation is allowed, including A → B → A, cannot become observations after a later Pause/Resume. The original receipt remains historical and the page is not reloaded.
3. Cancellation, Stop and close during the dispatched identity query cannot publish a current document. A cancelled read may be followed by an explicit retry after its actual callback frees the slot; stopped/closed contexts retain no handback candidate.
4. The identity command returns no authentication fields, remains stable across document-element replacement, does not bypass the normal authentication guard, and changes for a newly loaded document.
5. The production host manager, capability coordinator and native text executor receive the exact literal request `Set "Origin" to "Paris"`. The authentication guard pauses before planning. A controlled user-period transition replaces the form and changes the URL without loading another page. Authenticated Resume reacquires the page, completes the original field request once and preserves durable replay. The fixture observes one edit, one initial page request, no fallback/planner call and no callback/verification value in outgoing task messages.

The fifth fixture preloads a local login-like page inside its native-execution callback. Removing the fixture's credential control is not provider login verification, and literal compilation is not an actual-model natural-language result. It specifically checks production continuity from a pre-planning authentication pause.

The reviewed manifests contain **592 default host methods** and **72 focused methods**. The focused set includes the owned-browser class, all DOM methods affected by the shared bridge and selected host handoff methods. Source inventory checks, `git diff --check` and `xcrun swiftc -frontend -parse` for the six changed Swift files pass. Syntax parsing does not resolve symbols, type-check concurrency or build the app. No assertions have been executed or Swift changes compiled. See [the focused inventory](browser-history-handback-inventory.json).

## Remaining work

- A history change needs an earlier captured identity. A full user navigation followed by history changes before the first successful identity capture can still be rejected. Changes during initial load, failed identity capture, WebContent termination and back/forward-cache restoration need their own complete proof and qualification paths.
- KVO delivery, actor assumptions, A → B → A transitions and callback ordering require actual WebKit execution on supported macOS versions. Unexpected unordered notifications invalidate conservatively. This patch does not claim to observe every internal history event.
- Retained tasks with attempted/dispatched edits or scoped clarification targets are not automatically rebound to another form. Preserving verified effects and planning only the remaining authorized work still requires a reviewed continuation contract. Matching labels or values alone cannot erase action history or establish replacement-target authority.
- Fresh document identity is not proof that login succeeded, that the correct account is active, that a particular task page is open or that the whole original goal is complete. Account/page outcome checks, popup providers, results extraction, date controls and full travel/concert/movie workflows remain open.
- Page/AX/screenshot privacy, source-link handling, old stored callback values and resource qualification remain separate repairs. The new bounded identity calls require later latency/resource measurement as part of the 8 GB target; no fan or performance claim is made here.
