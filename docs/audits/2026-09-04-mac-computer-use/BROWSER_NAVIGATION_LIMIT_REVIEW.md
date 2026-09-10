# Read and verify the final permitted page

Source checkpoint: 2026-09-09. Parent: `fe1f8c3`. Source repair and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

A navigation allowance bounds opening another page. It does not establish whether information on the current page has been read, whether the request is complete, or whether control should be handed to the user.

The [research driver](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift) previously used `while visits.count < navigationLimit` around its entire orchestration loop. After the final allowed navigation, that condition skipped the destination's action selection, reading, result verification and login handoff. With a limit of one, it could open the initial search and immediately stop without reading it. A complete answer on the final permitted page was unreachable. Resume preserved the count and therefore could not inspect a page the user visited manually either.

The preceding [planning-lifetime repair](BROWSER_PLANNING_LIFETIME_REVIEW.md) bounds proposal delivery. It does not correct this category error between navigation and observation.

## Navigation admission and retained history

The driver now checks its existing navigation allowance at the relevant operation boundaries. Initial search, result-link opening, form query, action/result history traversal and their pending paths all check capacity before potentially navigating. Search refresh and search-term planning retain a fresh check before the subsequent navigation call. These ten checks reuse the owner-confirmed visit ledger and validate that it extends the driver's exact retained prefix.

The default allowance and its configuration clamp remain the existing 24 and 1–32 values. Resume and accepted goal answers do not reset it. A child confirmation retained before Pause still consumes its visit even if the driver's outer await was cancelled. A limit failure creates no new navigation stage or native request from the refused proposal.

The driver can continue current-page work after the last confirmed visit: observation, full-goal interpretation, form criteria, login handoff, result reading and native answer verification. Form input is not itself permission to dispatch a query. Both action-selected and result-selected history traversal still need navigation capacity.

An unexpectedly pending navigation with no remaining capacity is left pending. This change neither erases uncertain effects nor turns a missing receipt into an unattempted action. Existing journal reconciliation remains authoritative. Direct/manual browser navigation, redirects and page-authored effects are still accounted through their existing native histories and policies; this driver allowance is not a universal cap on all WebKit loads.

## Findings and user control

When another selected navigation is refused, the driver attempts to report its latest completed reading through the existing native source and freshness checks. Pending form/navigation state prevents this shortcut. An unresolved final-page reading also carries the limit reason. If no report can be prepared, the driver returns a nonterminal intervention message.

[Progress reports](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchReport.swift) carry an optional native `navigationLimit` pause reason. The reason appears outside quoted page data, in the report body and in its intervention guidance. The complete requirement ledger, surrounding text, quotation boundaries and existing byte limit remain mandatory; adding a reason cannot justify truncating the user's criteria. The message already participates in report identity, so differently worded limit reports receive different identifiers. Ordinary reports retain their existing text and guidance.

The reason flows through [owner report preparation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) and [native report construction](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultCandidates.swift). The [host](../../../host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift) uses the report's guidance when pausing. Existing status replay retains that guidance and the report, without another read or search. No protocol shape changes are needed.

The guidance explains that the user may continue manually and explicitly hand control back to review the current page. Handback still checks authentication and ownership. It does not grant additional navigation allowance. A verified answer can complete only through the existing complete-goal and fresh-source predicates; reaching a limit cannot relax price, quantity, date, source or other requirements.

## Authored verification, unrun

Nine new methods specify:

1. Complete single-page and multi-page answer assembly when the last required page uses the final navigation slot.
2. An over-budget offer remaining an unverified finding on that final page.
3. Login handoff and explicit handback with a one-navigation allowance.
4. Reporting the last page after a refused next-link choice, then rereading after handback without another native navigation.
5. Verified form input followed by a refused query, without repeating input on continuation.
6. Refused action-selected history traversal, without creating a history stage.
7. Refused result-selected history traversal while retaining its current findings and unresolved quantity.
8. Complete quoted sources, limit guidance, report identity and byte-boundary behavior.
9. Host pause, replay and explicit handback retaining the report reason without another initial search or terminal success.

Existing fixtures now expect the recovered final page to be read. Report rejection after page change, Pause and native callback cancellation runs through both ordinary and limit-reason source paths; excluded answer sources remain excluded. These are authored assertions, not execution results.

Ten changed Swift files pass parse-only checks. Active default/focused source inventories select 1798 / 1115 methods, with nine additions and no removals. This establishes syntax and source registration only.

## Remaining repairs and qualification

1. Add a distinct whole-task active-time and recovery policy. The prior loop could already repeat non-navigation recovery while its visit count stayed below the limit. Removing the misplaced outer condition does not establish meaningful progress or bound every recovery cycle. Native state changes, new useful evidence, successful effects and repeated model proposals must be distinguished.
2. Make remaining resource limits available in proposal context without confusing them with user requirements or native capability authority. Native admission must continue to enforce the actual limit independently.
3. Qualify cancelled returns, pending effects, manual navigation and authentication transitions under platform timing. A navigation allowance must not erase uncertain effects or provide retroactive source-history proof.
4. Continue the [repair checklist](../../../TODO.md). Global navigation-source completion remains restricted, and broader provider semantics, durable recovery and model competence remain open.
5. Keep live travel/concert/movie/login tests, model adaptation and 8 GB/thermal qualification at their later authorized stage. No app, inference, SSH or browser execution occurred for this source repair.
