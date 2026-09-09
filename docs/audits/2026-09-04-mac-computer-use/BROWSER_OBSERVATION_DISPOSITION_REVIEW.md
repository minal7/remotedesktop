# Distinguish unfinished loads from rejected and retired observations

Source checkpoint: 2026-09-09. Parent: `5e30e6e`. Source repair and prepared coverage only; builds, typechecking, assertions, inference and browser execution remain paused.

## First-principles finding

The [page-observation history](BROWSER_PAGE_OBSERVATION_HISTORY_REVIEW.md) records acceptance and adoption, but several native paths cleared an observed load or candidate without retaining why. An HTTP response rejection could clear the tracked navigation before a later failure callback arrived; the callback then had no exact binding. The checker could label the earlier episode unfinished even though the native owner had already stopped tracking it. Likewise, an accepted candidate replaced by a later page remained indistinguishable from a candidate still awaiting adoption.

A native tracking disposition is evidence of what the owner did with its state. It is not proof that a network request was cancelled, that an unrelated callback belongs to that request, or that the replacement page was adopted.

## Native changes

[OwnedBrowser](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) now records `observedNavigationEnded` immediately before dropping the tracked observed-navigation reference. Reasons distinguish a validated finish, a rejected finish or response, source blocking, a failure callback, supersession, Stop, Close, browser release and process termination. The record retains the tracked object's original correlation ID, parent session, ownership epoch and generation. Stop/reclaim cannot relabel that old object with the replacement claim's generation.

These records carry no destination origin or applied policy. A weak response callback can cause the native owner to retire its tracked slot; that does not upgrade the response to exact navigation-object evidence. The ordinary policy/failure callbacks remain separately recorded, including late callbacks whose object binding is missing.

Accepted page candidates gain a `retired` event with a reason when existing native code discards them: a new navigation or location, failed identity validation, task claim/admission, Stop/Close/release, process termination, or failed/blocked navigation. Retirement preserves the original candidate and carries no adopted source or handback operation. Successful adoption still records only adoption and clears the slots without inventing an additional retirement. A fixed pair of slots is handled directly, without an auxiliary collection.

Claim replacement can discard the earlier claim's log after recording its retirement. The new claim keeps the existing explicit discarded-history boundary; this does not create cross-claim completeness. Retirement may occur after a replacement has advanced the native generation, so its target remains the old immutable candidate rather than the current page.

The existing 512-observation and 128-page-event bounds are reused; total retained ordinal capacity remains 960. Omitted records still invalidate frozen history through the existing bounded-record path. Native history identity is version 7. No new gate query, DOM read, model call, navigation or await was added.

## Reconciliation

[ResultAssessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) version 12 checks native tracked-load endings separately from actual WebKit callback phases. A matched rejection or retirement can close a tracked observed episode without inventing a finished callback. A successful observed admission requires the real finished callback, matching native finish disposition and subsequent acceptance in order. Missing or mismatched endings remain explicit gaps.

The page checker pairs retirement with its exact earlier candidate and rejects unmatched, conflicting or duplicate dispositions. An old candidate can be retired and a different candidate adopted. A generation change during retirement is not treated as adoption of that new generation. Counts distinguish matched native endings/rejections and retained/matched candidate retirements, rather than inferring current loading or permission state.

[Planner instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserLinkPlanner.swift) now describe the current navigation/page fields together instead of appending another historical schema paragraph. Response correlation, redirect destination, same-document lineage and platform gaps remain intact. The [navigation-source completion gate](BROWSER_NAVIGATION_SOURCE_COMPLETION_GATE_REVIEW.md) remains active.

## Prepared coverage and allowed checks

One new [OwnedBrowserTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseOwnedBrowserTests.swift) scenario replaces a candidate through two controlled history changes, checks the exact retirement identity and confirms that only the newer candidate is adopted without a navigation receipt. Existing same-document, interrupted-load and successful/failed handback scenarios now check matched dispositions. The interrupted-load fixture waits for its exact provisional-start record before Stop/reclaim. The [scripted navigation scenario](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSourcePolicyTests.swift) checks callback, native finish and acceptance ordering, and that an ending does not invent a destination. Two [answer-assessment expectations](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift) advance to version 12.

Six changed Swift files pass parse-only syntax checking; the new fixture script passes `node --check` via stdin. Default/focused source inventories select 1636 / 953 methods: one addition, with none removed or renamed. These are syntax and inventory checks, not compilation or passing assertions. No scratch files were retained and no app/browser run, inference, SSH retry, push or installed-app replacement occurred.

## Remaining work

Full claim/retirement and control intervals, source-policy/goal lineage through login, transfer of already current documents, parent research/form continuation and platform callback qualification remain open. In particular, explicit native disposition does not make an unmatched late callback attributable, prove response/redirect correlation, or verify authentication. Continue the [repair checklist](../../../TODO.md); live travel/concert/movie tests and resource measurements remain deferred to explicit execution permission.
