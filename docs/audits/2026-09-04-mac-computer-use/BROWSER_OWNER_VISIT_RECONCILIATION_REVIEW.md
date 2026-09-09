# Reconcile research visits with native committed attempts

Source checkpoint: 2026-09-09. Parent: `dec1d12`. Source repair and authored regression coverage only. Compilation, test assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

The [history-reading repair](BROWSER_NAVIGATION_HISTORY_READING_REVIEW.md) binds an assessment to the native history it observed. It still lacked a way to establish correspondence between that native history and the research owner's confirmed visits. Visits retained operation names and goal hashes, but no native attempt, browser context or document generation. A name can be reused after a claim is retired; its text alone cannot identify the earlier effect.

Correspondence must work in both directions. An owner record must identify the exact native commit it claims. A native committed attempt without an owner visit must remain visible instead of disappearing from the workflow's history. Duplicate or reordered records must not pass merely because the counts match.

## Native and owner changes

[ComputerUseOwnedBrowser](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) now exposes a read-only historical attempt binding for a retained native document receipt. It requires automation-navigation provenance, the exact retained receipt, task/context, operation, document generation and the current native session/ownership epoch. Exactly one committed attempt with a terminal order must match. A forged document, manual observation, retired claim or omitted attempt cannot obtain a binding.

This historical lookup deliberately does not query the action gate or require the browser to be active. A completed child result must be recordable when Pause arrives before its outer return. It neither grants control nor authorizes an action. Receipt and claim identity checks still prevent attribution to a replacement context.

[ResearchTask](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) retains that immutable native attempt with each visit, alongside task/context and document generation. Missing native history remains missing; the owner can retain its historical navigation fact without fabricating the omitted attempt. Visit descriptions expose only their kind. The owner's ordered snapshot identity distinguishes a missing snapshot from an explicitly captured empty array and binds every visit's context, goal and native attempt identity.

[ResultCandidates](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultCandidates.swift) freezes the owner visit array alongside native history for navigation-constrained readings. Assessment identity version 4 binds both snapshots. The research owner checks the current visit array when validating or using cached readings, reports, answers and navigation choices. Link-selection input also requires its supplied owner history to match the reading. A history destination selected from a reading receives the existing native-history freshness check before beginning the revisit.

## Reconciliation and limits

[ResultAssessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) version 8 checks each owner visit against the exact immutable attempt in the captured native history: task/root/context, operation, generation, successful terminal record, and goal revision when a recorded policy supplies it. It counts distinct matches, checks increasing native terminal order, and finds committed attempts with no matching owner visit.

Missing owner history, mismatched bindings, duplicate visits, reordered commits and unclaimed committed attempts have separate diagnostic gaps. Native claim discontinuities, discarded history and attempt overflow keep owner reconciliation open. A captured empty owner history is distinguishable from an unavailable snapshot. Failed and pending native attempts remain in the pre-existing history diagnostics; they cannot become confirmed visits.

An unconfigured dispatch can have a real owner/receipt correspondence while still lacking source-policy evidence. Likewise, a correctly matched visit can retain a policy mismatch or earlier-goal policy. The count of matched visits says nothing about redirects, manual actions, authentication success, source compliance or verified offers. [Planner instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserLinkPlanner.swift) state these distinctions. Native identities and origins remain outside the diagnostic projection.

The global navigation-source completion gate remains active. Exact correspondence can now resolve the owner-visit gap for a continuous retained history, but callback coverage and episode/control/policy-lineage qualification remain necessary.

## Prepared coverage and allowed checks

Four new methods are authored and unrun:

- [SourcePolicyTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSourcePolicyTests.swift): exact native receipt binding survives Pause without querying control and rejects altered/manual/foreign documents; three real fixture visits reconcile distinctly and in order, while missing, empty, duplicate, reordered and foreign-context histories retain the appropriate gaps.
- [ResearchAnswerTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift): a reading binds its complete owner array and rejects an omitted planner history without qualifying the route; a direct native commit outside the research owner appears as an unclaimed attempt in a fresh reading while the older diagnostic stays historical.

Four existing scenarios gain assertions for reused operation names after Stop/reclaim, omitted attempts after native-history saturation, matched owner correspondence under loose versus exact source policies, and the updated diagnostic version after clarification/resegmentation.

Seven changed Swift files passed `swiftc -frontend -parse`. Source inventories select 1629 default / 946 focused methods, four additions each and no removed or renamed identifiers. No JavaScript changed. These are syntax and source-inventory checks, not compilation or passing assertions. No app/browser execution, inference, SSH retry, push or installed-app replacement occurred.

## Remaining repair order

1. Reconcile native observation episodes with dispatches and ordered control transitions. Exact owner/receipt correspondence does not upgrade a weak callback association or an unrecorded episode.
2. Define and reconcile temporal source-policy/goal lineage, including legitimate clarification/replacement and manual login boundaries. A configured policy mismatch is not automatically proof of a prohibited visit.
3. Qualify supported macOS/WebKit callback coverage, then replace the [navigation-source completion gate](BROWSER_NAVIGATION_SOURCE_COMPLETION_GATE_REVIEW.md) with qualified current and retained-history evidence.
4. Continue account/document/form recovery, criterion replacement and semantic/model qualification in the [repair checklist](../../../TODO.md). Live travel, concert and movie scenarios and resource measurements remain deferred to explicit execution permission.
