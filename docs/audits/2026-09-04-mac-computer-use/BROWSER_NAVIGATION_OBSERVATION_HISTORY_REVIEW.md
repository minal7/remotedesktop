# Retain native navigation observations without overstating their identity

Source checkpoint: 2026-09-09. Parent: `0eae9e1`. Native observation foundation and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

Follow-up: the [control-history foundation](BROWSER_CONTROL_HISTORY_REVIEW.md) adds ordered research Pause/resume and native reacquisition events, full session requirements, and per-window sign-in lifetime identities. It preserves native success separately from accepted workflow resume; full route qualification remains open. The counts below describe this earlier checkpoint.

## First-principles finding

The [dispatch log](BROWSER_NAVIGATION_DISPATCH_HISTORY_REVIEW.md) identifies requested operations, their original policies and terminal outcomes. It cannot reconstruct intermediate navigation from requested and final origins. A separate event record is needed, and each record must preserve the strength of its native attribution.

The installed WebKit SDK headers were inspected as local source documentation. The legacy action and response policy callbacks describe their requests/responses but do not supply the `WKNavigation` used by this adapter's pending continuation. The redirect callback supplies a navigation object but no destination request. Consequently, “this callback arrived while operation A was pending” is weaker than “this callback supplied A's exact native navigation object,” and the live WebView URL at a redirect callback is not automatically its destination.

The same distinction matters during login. A task policy can remain configured while a person navigates outside its automated browsing scope. Recording that configuration as if it were enforced on the human's login would falsify the history. Control-gate state also does not prove who initiated an event.

## Native source change

[ComputerUseOwnedBrowser](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) now retains bounded observations alongside its dispatch attempts:

- Main-document action and response decisions record allowed/cancelled status, observed origin, configured policy, and whether that policy was unchecked, absent, permitted the origin or blocked it.
- Native provisional start, redirect, commit-start, finish and failure callbacks record the exact pending or observed `WKNavigation` correlation when available. A missing or nonmatching object remains unattributed. Raw finish/commit callbacks remain observations; the separate dispatch outcome still requires the adapter's normal native completion checks.
- URL notifications record their origin and whether the existing observer considered their ordering trustworthy. They retain only slot correlation, not an invented navigation identity.
- Back/Forward policy decisions distinguish the exact retained native history item from a pending slot. The existing Instant Back admission behavior remains intact.
- Scripted or otherwise unrequested navigations receive a separate native observation identity. They do not acquire an invented automation dispatch entry.
- Main-page manual login decisions retain user-control gate state and an unchecked source policy. Sign-in-window events have a separate surface, no automated attempt association and no claim that the parent's source policy governed that window.
- WebContent termination retains an unattributed event in the current browser context rather than supplying a fabricated navigation object.

Observations retain the parent browser session, ownership epoch and document generation. Correlation is explicit: pending slot, observed slot, exact pending navigation, exact observed navigation, exact history item or none. The control field is only the gate state already obtained by the existing code; raw callbacks with no such check retain `unknown`. No additional `mayAct` call was added to observe an event.

The new redirect callback observes the live WebView origin without treating it as a destination request or an allow/cancel decision. Native action/response origins and actual policy decisions remain separate records. This patch does not claim to block a redirect earlier than the existing enforcement path or to have qualified every redirect hop.

The history snapshot identity advances when observations change and uses a new version tag. At most 512 observations are retained; the first overflow latches an explicit gap and changes the identity. Further callbacks after saturation allocate no new observation or origin. Entries keep origins rather than URL paths, queries, fragments, page text, error payloads or login values. Diagnostic descriptions remain redacted. The log stays private to native code and is not added to planner JSON.

## Prepared coverage and allowed checks

Three new methods in [SourcePolicyTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSourcePolicyTests.swift) are authored and unrun:

1. A native request distinguishes action/response slot correlation from exact provisional-start, commit-start and finish callbacks, preserving the actual policy decision and the limited knowledge of control state.
2. A cross-origin redirect retains its exact native navigation association while remaining an observation with no fabricated request decision or destination claim. Response/commit evidence stays separate, and diagnostics omit private callback data.
3. A script-triggered navigation receives its own observed identity and changes the history snapshot while leaving the automation dispatch list unchanged.

Six existing scenarios gain or refine assertions: policy replacement, rejected HTTP responses, main-page manual login, blocked scripted history, native [Back/Forward/revisit](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchHistoryTests.swift), and [sign-in popup/handback](../../../host-mac/RemoteDesktopHostTests/ComputerUseOwnedBrowserTests.swift). Policy replacement and replay checks specifically require unchanged dispatch attempts; unrelated late native observations are not mistaken for rewritten attempts or redispatch.

Four changed Swift files passed `swiftc -frontend -parse`. The one added scripted-navigation fixture passed `node --check` after substituting a literal local fixture origin; its JavaScript was not executed. Source inventories select 1616 default / 933 focused methods, three additions each and no removed or renamed identifiers. These checks establish syntax and source inventory only, not compilation or passing assertions. No app/browser execution, inference, SSH retry, push or installed-app replacement occurred.

## Remaining repair order

1. Qualify callback ordering and coverage on supported macOS/WebKit versions. Slot correlation, live URL snapshots and control-gate state must not be silently strengthened into exact operation or actor attribution. The local SDK also exposes newer action-correlation API, but its availability and semantics need qualification before depending on it.
2. Reconcile observation episodes, dispatches, native receipts and owner-confirmed visits. Preserve missing associations, failed attempts, policy changes, claim discontinuities, unordered notifications and either history overflow as explicit evidence gaps.
3. Bind actual pause, sign-in-window lifecycle and handback boundaries to those records. An observed sign-in surface is not proof of successful authentication, and unrequested activity must not become an automated receipt merely because automation was allowed at the time.
4. Define and implement the complete source/goal lineage check, then bind its sealed result to readings and final answer admission. Later unknown or violating activity must invalidate earlier eligibility. The [navigation-source completion gate](BROWSER_NAVIGATION_SOURCE_COMPLETION_GATE_REVIEW.md) remains active; these observations are not yet a positive compliance certificate.
5. Continue criterion replacement, account/form recovery, semantic/model qualification and the rest of [TODO](../../../TODO.md). Real-site travel/concert/movie tests and the 8 GB resource qualification remain deferred to explicit execution permission.
