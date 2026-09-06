# Continue observing pages after active browser navigation

Parent source: `c7b5e97`. Status: source implementation and prepared regressions only. No type checking, build, test execution, model run, app launch, computer use or real-website task ran.

## First-principles findings

The browser previously published a usable document after an explicit host `navigate` operation or an explicit handback of a page changed during user control. A normal link click, form navigation or history change while automation was active invalidated the old document but produced no new usable reference. The next semantic planning iteration could repeatedly fail with `pageChanged`, even after the destination loaded. A new native form request could fail at the same boundary before planning began.

This confused two different requirements. An action needs evidence of its attempted and verified effect; an observation needs evidence that it describes the current owned page. Refusing every fresh page without a host-created navigation receipt prevents normal browsing. Treating every fresh page as a successful requested navigation would instead invent effect evidence. The repair must make the page observable while preserving the missing-action-proof distinction.

Apple's [navigation-completion callback](https://developer.apple.com/documentation/webkit/wknavigationdelegate/webview(_:didfinish:)) identifies the navigation object that finished. The adapter additionally checks a successful main-frame HTTP response, current URL, browser generation and owner. None of these facts proves that the user's search or broader task succeeded.

## Source repair

Untracked main-frame navigations now retain their `WKNavigation` identity, browser generation, task owner, successful response URL and whether they began while automation was active. Successful completion creates a bounded observation candidate, not a document authority or navigation receipt. Failed responses, failed loads, replacement navigations, Stop, close and process termination invalidate the candidate.

Ordered URL changes within a loaded document now retain a separate active observation candidate as well as the existing user-control candidate. Reacquisition requires the same independently read page identity. A history transition from A to B and back to A still changes the generation, so the old document and field references cannot revive. Unexpectedly unordered URL notifications remain invalidations without authority.

`acquireObservedDocument` waits within the existing navigation timeout for a page already loading; it never reloads or retries that navigation. It then checks the current candidate, view, task owner, presentation, generation and URL, reads page identity and checks the candidate again before publication. A separate ownership epoch prevents an old waiter from attaching to a Stop/reclaim cycle with the same task ID and WebView. Cancellation or lost control prevents publication. A timeout leaves the load itself alone; a later independent observation may use its eventual successful completion.

Published documents have source `activePageObservation`, distinct from `automationNavigation` and `userControlObservation`. Their operation IDs never enter the navigation receipt map. The observed URL is a location, not proof of a requested destination. Existing native field references and page evidence remain stale after a transition; fresh planning creates new references.

The semantic browser-context provider now uses this asynchronous acquisition path. Native form target acquisition is asynchronous too, with an explicit main-actor provider type, so it can obtain the current ready page before discovering fields or loading a planner. The rest of the native task still retains its original targets and cannot silently switch documents after an effect.

Pages changed during user control remain unavailable to ordinary planning until explicit handback. A load that began during automation but finished while the user had control also requires explicit handback. Its origin remains `activePageObservation`; handback does not reclassify it as a requested navigation. The previous regression that permanently rejected an automation-time history change after Pause/Resume is revised to check this provenance and absence of an action receipt instead. An unchanged active page can still be observed normally; no user-control page is adopted merely because the action gate reopened.

## Prepared regressions and source checks

Five new methods cover:

1. Controlled link activation with an HTTP redirect and native GET form submission. The next browser-context request gets fresh result text, rejects old document/page references, keeps the original explicit-navigation receipt and creates no new action receipt or journal. Repeated observation makes no additional request.
2. An unsuccessful response and a held response that exceeds the observation wait. Neither publishes a current document; the timeout does not reload, and later successful completion can be observed once.
3. Cancellation, user takeover and Stop/reclaim with the same task ID while an observation waits for a held page. The old waiter cannot publish into the successor owner. A load completed during takeover still requires explicit handback.
4. Takeover, Stop and close during the asynchronous identity read for an active history change. The callback cannot publish after losing its scope and does not load the history URL.
5. Production semantic-executor composition after both a network result page and a history-based result update. The original question and bounded page context reach the planner, supported visible evidence can answer it, and no input is replayed or navigation receipt manufactured.

The existing user-history test now directly rejects ordinary observation before explicit handback. The active-history test retains A/B/A coverage and checks the new observation source after explicit handback rather than requiring the page to remain permanently unusable.

Default source inventory: **649** methods. The [focused inventory](browser-active-page-inventory.json) selects **139**. Both source inventory checks, syntax-only parsing of the six changed Swift files and whitespace checks pass. No assertions ran. These checks do not establish compilation, live WebKit callback ordering, rendered windows, actual planner behavior or provider compatibility.

## Remaining repair sequence

1. Compile whole browsing intent into supported intermediate actions and complete result requirements. This repair permits observation after existing actions; it adds no authority for an otherwise unsupported click, link choice or search submission.
2. Add document/control-bound link and submission operations, including explicit handling of prevented submission, same-page result updates, popups and uncertain effects. A fresh page alone cannot verify any of those operations.
3. Verify result identity, dates, locations, availability, counts and selected public sources. Page groups and rendered text alone do not prove a complete ticket-search result set.
4. Complete durable remaining-goal reconciliation across login, approval, navigation and restart. Fresh observation must not replay or upgrade an uncertain earlier form/input effect. Qualify the installed host/phone handoff and provider behavior later.
5. Compile and execute controlled regressions when authorized, followed by the real travel/concert/movie scenarios with explicit permission. Resource optimization and 8 GB/thermal qualification remain in the deferred performance phase.
