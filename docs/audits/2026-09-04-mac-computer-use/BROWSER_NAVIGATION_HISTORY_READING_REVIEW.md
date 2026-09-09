# Bind navigation-history assessments to their readings

Source checkpoint: 2026-09-09. Parent: `c0244e3`. Source repair and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

A reading can remain on the same document while its policy or control history changes. Document identity alone cannot establish that the earlier route assessment is still current. Restoring an earlier policy cannot erase a configuration that existed between the two installations.

The [ordered control history](BROWSER_CONTROL_HISTORY_REVIEW.md) retained dispatches, observations and handback events, but policy installation changed none of its records or identity. Result readings did not retain that history. The completion gate correctly withheld navigation-source answers, but its generic unverified status could not distinguish recorded policy mismatch from missing qualification evidence.

## Source repair

[ComputerUseOwnedBrowser](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) records accepted policy changes in the shared event order. Each retains the previous and installed native policies, parent session, ownership epoch and generation. Rejected changes produce no accepted record. An idempotent installation performs the existing guards without creating artificial history. Replacing and then restoring a policy preserves both transitions.

At most 64 installations are retained, with an explicit overflow marker. Every actual installation changes the history identity, including after saturation. Omitted navigation observations and control events now also change that identity without retaining another record or parsing its URL. Otherwise, a saturated log could make later activity invisible to freshness checks. The shared order advances only for retained entries, at most 832 ordinals. History identity uses version 4.

These installation events are not a complete ownership ledger. Policy clearing at Stop/claim remains represented by the existing claim-boundary marker; a later installation retains its then-current previous policy. Claim discontinuities and discarded other-task history remain explicit gaps.

[ResultCandidates](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultCandidates.swift) captures immutable native history after page validation when the complete interpretation, including retained clarification history, has a navigation-source obligation. Its assessment identity binds that snapshot using version 3. A task without this obligation does not acquire one merely because its browser has history.

Current reading validation compares the retained history identity with native history after page validation. Synchronous final answer validation and [research-owner progress-report delivery](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) also check it. Same-page handback, policy replacement/restoration, new observations and later overflow activity invalidate current use of an old assessment. Reading again captures new history; recall retains the original assessment as historical evidence.

[SourceRequirements](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserSourceRequirements.swift) checks exact navigation-policy correspondence for the compiled task/root/revision and restrictions. This is configuration correspondence only. Older goal policies require separate lineage reconciliation.

[ResultAssessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) version 7 projects bounded record counts and named gaps from that frozen history: missing/foreign history, claims, each overflow, unconfigured/pending/unsuccessful dispatches, unknown dispatch origins, current-goal policy mismatch, earlier/foreign policies, weak/unattributed/unordered observations and unreconciled control episodes. Owner-visit reconciliation and platform coverage remain explicit gaps even when retained policies match. A different interpretation cannot obtain the reading's history as if captured under that interpretation.

The blocked-source counter counts observations, not distinct requests or prohibited visits: a blocked callback can reflect successful prevention. The projection exports no native URLs, origins, policy/task/session hashes, credentials, event identities or positive compliance status. [Planner instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserLinkPlanner.swift) explain the limits. `navigationHistoryUnverified` and the global navigation-source completion gate remain active.

## Prepared coverage and allowed checks

Five new methods are authored and unrun:

- [SourcePolicyTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSourcePolicyTests.swift): accepted versus rejected/idempotent changes, ordering and restoration without erasure; bounded alternating installations with invalidation after each omitted change.
- [SourceRequirementsTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSourceRequirementsTests.swift): exact compiled policy/goal correspondence, refusal of loose or foreign-root configuration and preservation of separate answer-source scope.
- [ResearchAnswerTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift): same-page handback invalidates current assessment use while preserving historical recall; policy replacement/restoration invalidates reading and progress-report delivery and appears in the fresh diagnostic.

Five existing scenarios gain assertions for shared ordering, repeated control overflow, loose versus matching navigation configuration, earlier goal policies after resegmentation, and absence of an invented history duty for an answer-source-only task. Authored diagnostic coverage also checks for native identity/source leakage.

Nine changed Swift files passed `swiftc -frontend -parse`. Source inventories select 1625 default / 942 focused methods, five additions each and no removed or renamed identifiers. No JavaScript changed. These are syntax and source-inventory checks, not compilation or passing assertions. No app/browser execution, inference, SSH retry, push or installed-app replacement occurred.

## Remaining repair order

1. Reconcile native attempts/observation episodes with owner-confirmed visits, exact control transitions and goal/source-policy lineage. Installation mismatch is a configuration fact, not proof of a prohibited visit. Revised restrictions need explicit temporal semantics.
2. Qualify callback coverage and attribution on supported macOS/WebKit versions. Slot matches, ordered records and permitted final origins cannot certify a complete route.
3. Use qualified reconciliation to replace the [navigation-source completion gate](BROWSER_NAVIGATION_SOURCE_COMPLETION_GATE_REVIEW.md), including current/retained readings and late invalidation. This patch establishes freshness and diagnostics, not affirmative route eligibility.
4. Continue source/criterion replacement, account/document/form recovery and semantic/model qualification in the [repair checklist](../../../TODO.md). Live travel, concert and movie scenarios and resource measurements remain deferred to explicit execution permission.
