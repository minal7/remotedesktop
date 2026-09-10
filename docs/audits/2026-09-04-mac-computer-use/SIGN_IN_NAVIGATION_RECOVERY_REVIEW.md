# Sign-in child navigation and warning recovery

Source repair, 2026-09-10, following `a0ed922` and the [browser presentation review](BROWSER_PRESENTATION_STATE_REVIEW.md). Execution remains deferred.

## First-principles findings

1. **The child window and each load have different lifetimes.** The child failure callback previously overwrote its caption without checking which WKNavigation failed. A late failure from an earlier load could describe the page the person was currently using.
2. **Starting a retry is not recovery.** Clearing a warning on any URL change, repeated start or unrelated finish would hide a newer failure. The old implementation instead left the warning in place indefinitely, including after a real recovery.
3. **Displaying a provider page is not successful authentication.** WebKit may finish displaying a 401/403/500 page normally. The person needs its contents, while AI must retain the sign-in handoff. Neither an HTTP response nor a native finish proves account state.
4. **A provider child can outlive navigation in its opener.** The shared callback-scope check required the parent's document generation, URL revision and pending slots to stay unchanged. A legitimate parent change during the child's status publication could therefore cancel the child's response despite retaining the same native child and user-control owner.
5. **Display publication can reenter navigation.** Child status must retain its navigation-state revision through will-change as well as its native window/task owner. Otherwise a completed load can overwrite a newer warning in that same child.

The local SDK's `WKNavigationDelegate.h` identifies start/finish/failure as main-frame navigation callbacks and supplies the navigation object. Response policy supplies a WKNavigationResponse, without an exact WKNavigation. The repair uses those distinct contracts and does not infer exact policy-to-navigation correlation from timing.

## Implemented changes

[ComputerUseSignInNavigation.swift](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseSignInNavigation.swift) owns display-only state for one child. It retains only its active native navigation strongly and remembers completed/superseded identities weakly. It has no document receipt, action authorization, login result or Resume operation.

- A new native start selects the current load and captures the warning revision. Duplicate starts preserve that identity and revision. Known retired callbacks cannot alter status or restart the old load.
- Finish/failure must match the current navigation. Nil or foreign terminal callbacks cannot finish the active load; a foreign terminal identity is remembered so a later start cannot resurrect it.
- A successful finish clears a warning only when the same load began after that warning and no newer warning appeared. A supported blank page may finish displaying, but it does not clear a provider warning. An unsupported/unavailable page cannot claim recovery.
- A matched cancellation reports an interrupted request without inventing a network failure or erasing a warning. A matched ordinary failure reports load failure unless a newer policy/provider warning already explains the problem.
- Unsupported destinations/documents and HTTP 400–599 responses set typed warnings. Provider HTTP error pages remain allowed when otherwise displayable so the person can read them. Raw NSError descriptions, URL paths, queries, fragments and credentials do not enter these messages.
- Child state is allocated with its exact native child and detached before native close/Stop callbacks. Presentation retains the child state identity and revision across will-change. The UI displays control ownership, page activity and warning separately; its compatibility detail publisher remains available to the existing fixtures.
- Child policy callbacks retain the parent native session/task epoch, exact child instance and control owner. They do not require the opener's document generation, URL revision, main navigation slots or source policy to remain unchanged. Native cleanup, parent/child replacement and owner changes still reject the old callback; same-owner early Resume still retains the child.
- Parent navigation handling retains its existing checks. Child history remains unbound display evidence; this new identity tracker does not promote child activity into parent navigation receipts or task success.

## Authored cases — not executed

Seven methods in [ComputerUseOwnedBrowserTests.swift](../../../host-mac/RemoteDesktopHostTests/ComputerUseOwnedBrowserTests.swift):

| Method | Intended evidence |
| --- | --- |
| `testSignInNavigationRequiresCurrentNativeIdentity` | Duplicate, foreign, nil and retired native identities cannot replace or finish current state |
| `testSignInWarningNeedsASubsequentMatchingSuccessfulLoad` | New warnings survive the current load and clear only on a later matching success |
| `testSignInCancellationBlankPageAndProviderErrorPreserveWarnings` | Cancellation/blank navigation cannot invent recovery; specific newer warnings survive generic failure |
| `testSignInNavigationReleasesCompletedNativeObjects` | Active identity is retained and completed identity is weak |
| `testSignInStatusPublicationCannotOverwriteANewerNavigationWarning` | A newer navigation/warning wins across presentation invalidation |
| `testSignInProviderErrorRecoversWithoutReturningControlToAI` | A real loopback child displays HTTP 403, retries to a supported page, clears the warning and preserves paused ownership/parent state |
| `testSignInResponseKeepsItsChildOwnerWhileTheParentNavigates` | A parent navigation injected during child response publication does not cancel the retained child's provider error page |

The final two use the existing headless WKWebView/loopback fixture when eventually executed. The opener-navigation case injects a start for an actual returned parent WKNavigation to exercise reentry; it does not prove native callback ordering. The state cases use NSObject identities and do not substitute for WebKit qualification.

## Source verification

- Four Swift files pass `xcrun swiftc -frontend -parse`; no typecheck or compilation is implied. Source review also corrected the new fixture's initializer argument order against the actual declaration.
- The explicit Xcode project includes the new file/group/build-phase entries and passes `plutil -lint`.
- Nine inventories match selected source: **2025 default host / 1342 focused browser / 13 sign-in recovery / 14 browser presentation / 9 sign-in lifecycle / 7 separate visible URL cases / 6 separate visible process-failure cases / 113 client core / 110 client acknowledgement**.
- The [bounded recovery inventory](sign-in-navigation-recovery-inventory.json) contains seven new methods and six existing child/presentation cases. Default/focused expectations were extended with these explicit reviewed names.
- Whitespace checks pass. The documentation scan covers 250 Markdown files and 2118 local targets with no missing files; anchors are unchecked. The effective hook directory has zero executable non-sample hooks. These remain source/configuration checks only.

No assertions/tests, builds, typechecks, app launches, native capture, browser/computer-use actions, inference or model changes ran. The installed app, saved performance work and model assets remain untouched.

## Remaining qualification

- Run the authored cases after permission and inspect actual child activity/warnings, rapid replacement/cancellation, parent navigation and same-owner handback. Test HTTP error pages and real network failures on the supported macOS/WebKit versions.
- Native ordering remains unqualified. A first-seen start that was already stale at delegate entry cannot be identified solely by its new object identity. A failure without a known matching start cannot establish the current load's failure through this tracker.
- Policy/response callbacks still lack exact WKNavigation correlation. A late policy warning is retained conservatively and cannot be cleared by an already-started load. Its arrival is not proof that it belongs to the currently displayed document.
- A matching native finish and supported URL mean only that a page finished displaying. They do not verify account identity, credentials, MFA, CAPTCHA, successful login, parent-page applicability or natural-language task completion. The open child continues blocking AI browser effects; closing it still requires explicit handback and parent reacquisition.
- Complete the other [repair checklist](../../../TODO.md) items and the later authorized travel/concert/movie scenarios. Model choice, RTX 3080 work, 8 GB resources and thermal qualification remain deferred.
