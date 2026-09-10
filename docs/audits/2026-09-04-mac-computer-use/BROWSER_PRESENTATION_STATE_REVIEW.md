# Browser task, page and control presentation

Source repair, 2026-09-10, following `c518f6a` and the [URL delivery review](BROWSER_LOCATION_DELIVERY_REVIEW.md). Execution remains deferred.

## First-principles findings

1. **A task ending and a page changing are independent facts.** One `detail` string represented both. A delayed URL notification could replace Stop or process failure with “Page changed.” A progress notification says nothing about recovery from an earlier failure.
2. **Observable publication is a call into other code.** The five `@Published` display properties notified subscribers before their stored values changed. A subscriber could Stop, Close or claim another task, only for the older setter to overwrite the replacement's value after it returned. Checks following that setter protected later operations but could not repair the already overwritten value.
3. **A control snapshot and its handler form one binding.** Assigning the new handler before publishing the snapshot exposed an old snapshot with a new handler during will-change. Closing a provider window could also publish a newer binding and then return to an older `updateTaskControls` call that replaced it.
4. **Each displayed native view needs its own scope.** Both views held a fixed WKWebView and read live shared context. A retired view could briefly display a successor's controls, and an old child Close button addressed whichever child was current when clicked.
5. **A cancelled request is not necessarily a broken page.** Take Control used the same error-caption path as a failed load. Programmatic Close also published “Stopped,” obscuring the difference between retaining and releasing the browser.

These are presentation defects. Fixing them cannot establish input authority, native quiescence, page identity, successful authentication or task completion.

## Implemented changes

- Added [ComputerUseBrowserPresentation.swift](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserPresentation.swift), a separate main-actor display model, registered in the explicit Xcode project. Task lifecycle, page activity, page issue, child display and control binding are separate fields.
- Will-change remains before assignment. Per-field revisions and a caller-owned scope check run after it; obsolete writes are discarded. A multi-field update applies its still-current deltas to current state, preserving independent nested changes. Nested will-change sends are folded into the surrounding invalidation.
- Value notifications follow committed state. Their delivery is serialized across subscribers. Remaining field refreshes read the latest state when delivered, so they do not replay an abandoned batch's retained captions. They are display refreshes, not an event history. Explicit same-value site and child-detail writes remain observable for the existing interruption fixtures.
- The browser's computed getters expose authoritative state. Explicit `displayedSiteChanges`, `detailChanges`, `signInSiteChanges`, `signInDetailChanges` and `taskControlsChanges` publishers replace the old projected-property subscriptions in fixtures. Production SwiftUI continues observing the browser's forwarded `objectWillChange` publisher.
- Claim and retirement update task presentation coherently under the task ownership epoch. A claim also rechecks page generation, URL revision, takeover and empty native work slots after publication before its caller can reuse prior page data. Parent status mutations retain native session, task, page generation, URL revision, takeover and control owner. Child mutations retain the exact child and parent owner but allow parent document changes and same-owner control-phase changes during sign-in.
- Stop and Close persist across ordinary page activity. Close, including a nested upgrade from Stop, now reports “Closed.” Retained page failures have their own visible message and survive generic opening/URL changes. They clear on a new task, successful accepted page completion, or the existing validated page-admission/handback path. A matched observed-navigation failure now reports a page issue. Ownership loss reports an interrupted request without creating a new page-failure banner.
- Control publication commits snapshot and handler together. An update-request identity is captured before child cleanup; a newer update or changed task epoch defeats the old request both after cleanup and after will-change.
- The main view shows task status separately from neutral page activity and failure. Retired task guidance is hidden. An open sign-in child reports that AI is waiting even during a transient same-owner Resume phase. Controls are shown only for the exact current native parent/child and matching task. Child Close passes its exact native view and cannot close a replacement.

The compatibility `detail` getter gives retirement priority, then the retained page issue, then activity. The visible main view uses the separate fields. Neither projection is used to authorize a document or an effect. Existing host validation still receives the rendered control snapshot unchanged.

## Authored regression cases — not executed

Six new methods in [ComputerUseOwnedBrowserTests.swift](../../../host-mac/RemoteDesktopHostTests/ComputerUseOwnedBrowserTests.swift):

| Method | Intended boundary |
| --- | --- |
| `testPresentationWillChangeKeepsLatestFieldAndIndependentChanges` | A newer same-field write wins; claim reset preserves independently updated page/failure state |
| `testPresentationSerializesNestedValueDeliveryForEverySubscriber` | Two subscribers see ordered site values and committed getters during nested delivery |
| `testPresentationRetainsTaskAndFailureAcrossPageActivity` | Progress cannot erase retirement or failure; explicit recovery and new claim clear failure |
| `testControlPublicationKeepsSnapshotAndHandlerInOneBinding` | Will-change sees the old complete binding and a newer update defeats an abandoned one |
| `testRetirementWillChangeCannotRestoreStatusOverAReplacementClaim` | Replacement claim from retirement invalidation retains its current status |
| `testControlOwnerChangeKeepsNewerBindingFromChildCleanup` | The actual child-close publication cannot let an older control-owner update overwrite a newer binding |

The last case uses the existing headless WKWebView/loopback fixture when eventually executed. Existing publication cases use the explicit committed-value publishers. Four old Close expectations now distinguish Close from Stop. The existing opt-in visible queued-URL cleanup case additionally requires the Stop caption to survive delivery. Its visibility/environment gate remains unchanged.

## Source verification

- Three changed Swift files pass `xcrun swiftc -frontend -parse`. This is syntax checking, not type checking or compilation.
- The Xcode project passes `plutil -lint`; the new source has its file/group/build-phase entries.
- Nine reviewed inventories match their selected source identifiers: **2018 default host / 1335 focused browser / 14 presentation / 17 URL delivery / 7 separate visible URL / 11 native navigation identity / 6 separate visible process failure / 113 client core / 110 client acknowledgement**.
- [Presentation inventory](browser-presentation-inventory.json) selects the six new cases and eight prior publication/retirement/sign-in cases. New names were added explicitly to the existing reviewed default/focused sets; discovery was not used to manufacture expectations.
- Whitespace checks pass. The local documentation scan covers 249 Markdown files and 2111 local targets with no missing files; anchors are unchecked. The effective hook directory contains zero executable non-sample hooks. These are source/configuration checks only.

No tests/assertions, typechecks, builds, app launches, native capture, browser actions, inference or model changes ran. The installed app, model assets and deferred performance stash remain untouched. The volume reports approximately 82 GiB available; no generated-file cleanup was needed.

## Remaining work

- Execute the focused state and native fixtures only after permission. Confirm actual Combine/SwiftUI invalidation, rendered multiwindow controls and native callback behavior; syntax and inventory checks do not prove them.
- Review child error recovery independently: its last reported warning currently lasts until replacement/reset. A late callback must not clear a newer warning; clearing it needs the correct child navigation scope. Main-page recovery is not proof that sign-in succeeded.
- Qualify actual host/phone Pause acknowledgement, pending native effects, login providers and explicit handback. The browser child still blocks AI effects and closing it does not resume automatically.
- Complete the outstanding capability and display/input repairs in [TODO.md](../../../TODO.md), then qualify complete natural-language travel, concert and movie requests on real sites when authorized.
- Resource measurement and model selection remain later work. This patch establishes no 8 GB, thermal, model-quality or whole-task correctness result.
