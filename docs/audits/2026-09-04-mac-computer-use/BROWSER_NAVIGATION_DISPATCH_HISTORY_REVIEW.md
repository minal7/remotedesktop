# Retain the native policy and outcome of navigation dispatches

Source checkpoint: 2026-09-09. Parent: `46f9a55`. Native history foundation and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

A completion check needs evidence about actions that actually reached dispatch admission, including unsuccessful work. A set of operation IDs proves that attempts were recorded, but does not say which source policy governed them. A later successful page or policy installation cannot reconstruct that missing association. Cancellation also cannot turn a dispatched request back into an unattempted operation.

The [completion gate](BROWSER_NAVIGATION_SOURCE_COMPLETION_GATE_REVIEW.md) already prevents a navigation-source field from authorizing a completed answer. This repair starts the native evidence needed to replace that gate with a qualified positive path. It deliberately describes dispatch history: it is not a complete route history, proof that a network request reached a server, or proof of source compliance.

## Native source change

[ComputerUseOwnedBrowser](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) now retains a bounded `ComputerUseBrowserNavigationDispatchHistory`. Its constructors and mutation functions are confined to the owning source file; consumers can request a value snapshot only under current task ownership. There is no model-facing constructor, payload field or planner context for this history.

Each attempt records a fresh native identity, operation ID, browser session, ownership epoch, document generation, the exact source policy captured at dispatch, requested origin and optional native Back/Forward source operation. A missing policy stays missing. The entry is created at the existing attempt boundary after cancellation, ownership, source and prerequisite checks, immediately before the native load/history dispatch. Policy refusals before this boundary do not become dispatched attempts.

The exact pending continuation carries the new attempt identity. Successful native document completion records its committed origin and `documentCommitted` outcome. Failure, source refusal after dispatch, cancellation/ownership loss and timeout retain distinct terminal outcomes without inventing a committed origin. Later DOM or parent-workflow verification remains separate: a committed document is not a completed research task.

Origins use the existing strict scheme/host/effective-port representation. The new records do not store URL paths, query strings, fragments, credential material, page content or login callback text. Diagnostic descriptions expose only counts and outcome categories. The native dispatch record does not replace the original document receipt or its exact URL bindings.

Replacing the current source policy leaves earlier entries unchanged. Stop followed by reclaiming the same task preserves those entries and marks a claim boundary. Reusing an operation ID after reclaim produces a distinct native attempt identity and ownership epoch. Closing and recreating the browser preserves the same task's log while subsequent attempts carry the new browser session. A different task starts a separate log with an explicit marker that another claim's history was discarded. Returning to an older task after that replacement cannot present the resulting empty log as pristine history.

The log retains at most 64 entries across repeated claims of the same task. Further attempts set an overflow marker and change the snapshot identity, while retaining the earlier entries. Existing navigation behavior is not broadened or blocked by this diagnostic bound. Any future compliance check must treat overflow and missing continuity as incomplete evidence, not ignore the omitted work.

Only the existing native dispatch path creates attempt records. Manual login and adopted handback documents do not acquire synthetic automated dispatch receipts. The claim-boundary marker specifically covers Stop/reclaim; its absence does not establish that no manual pause, handback or scripted transition occurred. Tracking those other transitions remains necessary.

## Prepared coverage and allowed checks

Six new methods in [SourcePolicyTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSourcePolicyTests.swift) are authored and unrun:

- Native origins, exact per-attempt policies, immutable snapshots, policy replacement and redacted diagnostics.
- Pending work followed by cancellation, then a failed response, retaining both attempts without committed origins.
- A timed-out native load retaining its attempt.
- Same-task Stop/reclaim and browser recreation, preserving earlier records while distinguishing new native identities, epochs and sessions.
- A different task replacing the retained history, including a later return to the earlier task with an explicit continuity gap.
- Bounded storage across 64 retained dispatches and a further dispatch after reclaim. This future fixture uses 65 sequential native loads; none ran during this source-only repair.

Three existing source-policy methods gain assertions for refusals before dispatch, terminal redirect outcomes and manual login without invented automation receipts. The native [Back/Forward/revisit scenario](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchHistoryTests.swift) gains checks for exact history-source operation IDs, replay without another dispatch, and a direct native branch that remains visible even though it is absent from owner-confirmed visits.

Three changed Swift files passed `swiftc -frontend -parse`. Source inventories select 1613 default / 930 focused methods, six additions each and no removed or renamed identifiers. No JavaScript changed. These are syntax and source-inventory checks, not compilation or passing assertions. No inference, browser execution, SSH retry, push or installed-app replacement occurred.

## Remaining work

1. Extend the native records with appropriately attributed main-frame policy actions, redirects, responses, cached restoration and unrequested/scripted transitions. Qualify callback ordering and any coverage gaps before claiming a complete route.
2. Represent manual pause/login/handback boundaries without attributing human actions to automation. Join these observations to the exact session and claim history, and reconcile unknown activity.
3. Reconcile native attempts with owner-confirmed visits and policy/goal lineage. Entries with no policy, a claim gap, discarded history, a failed attempt or overflow require explicit treatment. The log's native identity does not by itself prove the entire goal history.
4. Bind qualified route evidence to readings and final answer admission, including later visits after a reading. The `navigationHistoryUnverified` completion gate remains active; this patch supplies no positive compliance certificate.
5. Continue the broader [repair checklist](../../../TODO.md), including criterion replacement, account/form recovery, model qualification and the later 8 GB resource measurements. Real-site scenarios remain subject to explicit execution permission.
