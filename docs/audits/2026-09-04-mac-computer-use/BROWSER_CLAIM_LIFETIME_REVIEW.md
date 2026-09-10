# Retain ordered native claim lifetimes

Source checkpoint: 2026-09-09. Parent: `3026735`. Source repair and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

A task name is not a lifetime. The same task can stop, reclaim an existing browser or create a replacement browser. A Boolean claim-boundary marker retains the existence of a discontinuity, but cannot show which side contains an attempted navigation, its terminal result or a control event. Browser creation may also occur after a claim, so an arbitrary preallocated session identifier cannot establish that a native session already existed.

The [navigation-history sequence](BROWSER_NAVIGATION_SOURCE_COMPLETION_GATE_REVIEW.md) requires temporal attribution. [Control-episode reconciliation](BROWSER_CONTROL_EPISODE_RECONCILIATION_REVIEW.md) distinguishes Pause, native handback and workflow acceptance; this repair adds the native claim intervals within which those retained records occurred. Neither kind of correspondence proves route compliance or current permission.

## Native lifecycle records

[The owned browser](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) now records claim start, native session allocation and claim retirement with one shared history order. Records retain the ownership epoch and document generation. A claim begun without a browser has no session value. Creating its native browser records that session separately; reclaiming an existing browser starts the new epoch with that existing session.

Stop closes pending navigation, tracked observations and page candidates before recording retirement under the original epoch. The pending navigation's terminal disposition therefore precedes retirement; a later same-task claim cannot inherit that attempt as its own. Explicit Close records its retirement cause when it performs the first retirement. A later Close or duplicate Stop does not rewrite a claim that is already retired. The existing action gates and interrupted-DOM ownership rules remain unchanged.

An idempotent claim does not add a second start. A rejected claim adds no lifecycle event. Replacing another task records the outgoing retirement before its ledger is discarded; the successor retains the existing `beganAfterAnotherClaim` gap, not a claim to complete cross-task history. Earlier value snapshots remain historical copies. This is in-memory evidence, not durable recovery across process loss.

The claim stream retains at most 128 events. Further events set an explicit overflow marker and still change the history identity, invalidating frozen readings without allocating an unbounded log. The existing claim-boundary flag remains. Claim events contain no URLs, credentials or user text, and their debug descriptions expose only the phase. Native history identity now uses version 8.

## Temporal reconciliation

[Result assessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) constructs native claim intervals and checks each retained dispatch start/terminal, navigation observation, control event, policy installation and page-observation event against them. A record needs the exact epoch, an established matching session, an order inside the claim and a compatible generation. Session creation and retirement must pair with the active claim. Missing starts, reused or overlapping claims, out-of-order events, duplicate orders, unmatched session/retirement events and foreign or out-of-interval records remain distinct gaps.

The diagnostic separately reports claim, retirement, open-claim and session-creation counts, plus retained and matched activity-record counts. An open claim describes the frozen history; it does not query the action gate or establish that automation may currently act. Matching a retained callback's scope does not strengthen a weak callback/object association or identify whether a person or a website script initiated it. Missing records and overflow cannot produce complete-history evidence.

Assessment context version 14 includes `claim_history` inside `navigation_history_at_reading`, with counts and gap names only. Date-replacement metadata is retained when both features are present. Date-only contexts keep their existing version. [Link-planner instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserLinkPlanner.swift) explain that claim correspondence cannot establish authentication, accepted Resume, source-policy lineage or platform coverage.

The global [navigation-source completion gate](BROWSER_NAVIGATION_SOURCE_COMPLETION_GATE_REVIEW.md) remains active. Existing discontinuity, control, owner-history, response-association and platform gaps are not cleared by the new claim counts.

## Authored verification, unrun

Four new [source-policy methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSourcePolicyTests.swift) are registered:

- Blank claims retain exact Stop/Close retirement, reject unavailable admission, preserve earlier snapshots and create no browser or control authority.
- A pure diagnostic over captured lifecycle records rejects removed/reordered/repeated events, duplicate activity orders, missing session creation, activity after retirement, foreign sessions, invalid generations and overflow. Its projected context excludes native identities.
- Repeated blank Stop/reclaim cycles reach the 128-event bound, retain the overflow gap and continue invalidating snapshots after saturation.
- A held native dispatch stopped before response records its terminal ownership-loss result before retirement. Reclaim preserves that earlier lifetime and produces no successful receipt for the stopped operation.

Existing cases now specify all-record correspondence across three real fixture visits; separate claim/session lifetimes through Stop and browser recreation; and the retained gap when another task's history is discarded. Policy-installation and shared-record ordering expectations now include claim/session events. Three [answer-context expectations](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift) are updated for version 14, including date-replacement metadata accompanying a historical navigation-source label.

Five changed Swift files pass parse-only checks. Default/focused source inventories select 1763 / 1080 methods, with four additions and no removals. These checks establish syntax and source registration only. None of the assertions, callback sequences, retirement timing, field behavior, model choices or live website outcomes has been executed or qualified.

## Remaining repair order

Source follow-up: [policy lineage and installation-order reconciliation](BROWSER_POLICY_LINEAGE_REVIEW.md) now compares recorded configurations with exact accepted ancestors and checks their native installation/use sequence. Semantic correction, temporal intent changes, actor attribution and platform qualification remain open; the counts above describe this earlier checkpoint.

1. Reconcile source-policy and goal lineage across legitimate answers, explicit replacements and correction of earlier interpretations. A policy installed now cannot certify earlier activity.
2. Reconcile workflow/manual-control intervals with navigation initiation, observed-page adoption and required task criteria. Native claim scope alone cannot identify the actor, prove login success or rebind pending form duties to a changed document.
3. Qualify macOS/WebKit callback and redirect coverage, late events across retirement, real account handoff and source-constrained completion before enabling affirmative route evidence. Cross-task ledger replacement and process loss still retain missing history.
4. Continue complete semantic goal compilation, broader corrections, form/document recovery and result verification in the [repair checklist](../../../TODO.md). Alternative-model comparisons, authorized RTX 3080 adaptation and the 8 GB resource target remain unqualified. Live travel/concert/movie tests still require explicit permission.

No SSH retry, model work, push, installed-app replacement or generated-file cleanup occurred in this checkpoint.
