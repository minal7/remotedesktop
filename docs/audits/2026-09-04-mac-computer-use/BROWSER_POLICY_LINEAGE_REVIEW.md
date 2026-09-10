# Reconcile installed policies with accepted goal ancestry

Source checkpoint: 2026-09-09. Parent: `802d770`. Source repair and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

A different goal hash does not prove an earlier goal. It may identify an accepted ancestor, a sibling answer, another root or an unknown revision. Conversely, an unrelated clarification need not change the user's website restrictions. Treating every different revision as one unresolved earlier policy loses that distinction.

Configuration has a separate time dimension. A policy that matches the goal today cannot prove which policy governed a previous dispatch. Installing A, installing B and restoring A must retain B and every action recorded under it. Matching the last configuration alone cannot repair a disagreement in the earlier installation/use sequence.

This follows [ordered claim lifetimes](BROWSER_CLAIM_LIFETIME_REVIEW.md) and [retained question-time interpretations](BROWSER_CLARIFICATION_POLICY_HISTORY_REVIEW.md). It advances diagnostic correspondence; the [navigation-source completion gate](BROWSER_NAVIGATION_SOURCE_COMPLETION_GATE_REVIEW.md) remains active.

## Exact ancestor restoration

[Accepted turns](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalClarification.swift) now retain the prior proposal's disposition and proposed question alongside its existing digest and complete requirement snapshot. These are flat native records. They do not recursively embed the old input, enter model context or change the answer wire. The existing prior-proposal digest already binds the disposition, question topic/scope and requirement IDs.

[Goal input](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalPlanner.swift) can recover only an actual accepted answer prefix. It copies the original date context directly, retains the exact earlier answer records and checks the prefix digest against the next accepted turn. It does not reconstruct timestamps through floating-point conversion or accept an arbitrary hash with the same root.

Historical proposal restoration uses that prefix and the complete sealed snapshot, then requires the reconstructed proposal digest to match. A proposal whose disposition was clarification remains clarification; restoring it cannot manufacture a research disposition or new execution authority. Ordinary current-owner and goal-revision checks continue to govern work.

## Configuration lineage

[Source requirements](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserSourceRequirements.swift) compare each policy with the current interpretation or the exact interpretation sealed before an accepted answer. The diagnostic distinguishes:

- A matching current configuration, a mismatch and uncompiled current requirements.
- A matching ancestor configuration whose compiled navigation scope is unchanged, a matching ancestor whose scope changed, and a matching ancestor with unresolved current compilation.
- A mismatch with the ancestor's own restrictions, an uncompiled historical interpretation, or missing historical interpretation evidence.
- An unknown/sibling revision and a foreign task/root.

An ancestor comparison recompiles only its accepted prefix, so later answers do not retroactively enter its source requirements. The current compiler still retains earlier concrete restrictions through resegmentation. Comparing navigation scopes leaves answer-source restrictions separate; unresolved complete source compilation still withholds a positive comparison. Existing host filtering remains permitted when there is no explicit navigation-source requirement.

The sealed interpretation is not proof that the model originally classified the user's words correctly, nor is it a record of every interpretation made between questions. Configuration correspondence with that snapshot must not be presented as semantic or route qualification.

## Policy order within claims

[Result assessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) separately checks the recorded policy installation chain and policy uses in shared native order. Each claim begins without a configured policy. An installation's previous-policy value must match the preceding installed configuration for that epoch; each dispatch or main-document observation must carry that configuration. Different epochs do not inherit configuration merely because their task names match. Existing claim-scope reconciliation checks session, generation and lifetime correspondence.

Configuration mismatches, missing installation links, duplicate orders, claim gaps and overflow remain visible after a later restoration. A use with no policy is counted as unconfigured even if it agrees with the empty configuration state. Callback/use counts are not distinct network requests. Sign-in-child observations remain outside the parent document-policy comparison; manual activity and authentication retain their separate controls and history.

Assessment context version 15 adds `policy_history`: installation/use counts, matched and unconfigured use counts, counts of distinct configurations by lineage status, and gap names. It contains no native IDs, origins, URLs or goal hashes. [Planner instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserLinkPlanner.swift) explain the limits. Date-replacement metadata remains present when both diagnostics apply; date-only contexts retain their existing version.

A matching ancestor with unchanged navigation scope no longer receives the generic earlier-goal gap solely because an unrelated answer changed the revision. Changed/uncompiled ancestor correspondence still receives that gap, a sibling/unknown revision receives its own gap, and earlier configuration mismatches remain mismatches. No new answer eligibility or navigation authority follows from these changes.

## Authored verification, unrun

Six new methods are registered:

- Four [source-requirement methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSourceRequirementsTests.swift) specify exact restoration through two accepted answers with unchanged clocks and source resegmentation; unchanged versus changed restrictions, earlier/current mismatches and unresolved current scope; sibling and foreign-root rejection; and preservation of a historical clarification disposition and its question.
- Two [source-policy methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSourcePolicyTests.swift) specify installation/use ordering through A/B/A restoration, missing links, wrong uses, duplicate orders, overflow and claim isolation; and actual native fixture dispatches under two recorded configurations with later restoration. Earlier snapshots remain unchanged.

The existing [research-answer fixture](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift) now expects an unrelated clarification to reconcile its matching ancestor policy while retaining platform/route gaps and withholding completed answers. Three context-version expectations include the new diagnostic version.

Eight changed Swift files pass parse-only checks. Default/focused source inventories select 1769 / 1086 methods, with six additions and no removals. These are syntax and source-registration checks only. No assertion, callback ordering, source interpretation, model decision, provider result or account transition has been executed or qualified.

## Remaining repair order

1. Distinguish correction of an earlier model classification from an explicit user change of website restrictions. Define when a new restriction applies to future actions and how prior activity affects the complete task. Current scope-change diagnostics do not implement general source-policy supersession.
2. Reconcile workflow/manual-control intervals, route initiation and required form criteria across login and document transitions. A policy snapshot does not identify the actor, prove authentication or repair an uncertain pending effect.
3. Qualify response/redirect association, cached navigation, callback coverage and retirement races before enabling affirmative navigation-source completion. All-request network restrictions remain distinct from top-level document-source policy.
4. Continue complete semantic goal compilation, broader corrections, result verification and durable account/process recovery in the [repair checklist](../../../TODO.md). Live travel/concert/movie testing still requires explicit permission. Model comparison, RTX 3080 adaptation and 8 GB resource qualification remain deferred to their authorized stage.

No SSH retry, model work, push, installed-app replacement or generated-file cleanup occurred here.
