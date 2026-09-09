# Keep navigation-source completion dependent on actual history

Source checkpoint: 2026-09-09. Parent: `a7b1f93`. Source repair and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

Follow-up: the [native dispatch-history foundation](BROWSER_NAVIGATION_DISPATCH_HISTORY_REVIEW.md) retains per-attempt policy, origins and terminal outcomes, including across same-task Stop/reclaim. It does not yet qualify complete routes or replace this completion gate. The counts below describe this earlier checkpoint.

## First-principles finding

“Report results from these sites” constrains evidence. “Visit only these sites” constrains actions over time. Their proofs differ. A permitted final document, the latest installed source policy and a model's description of earlier visits cannot establish the actual route taken by the automation.

The [previous repair](BROWSER_ANSWER_SOURCE_COMPLETION_REVIEW.md) matched answer-source requirements against the policy used for a native reading. It left a separate completion shortcut: an outcome or condition labeled `navigationSource` could pass the answer compiler solely because of its field. A navigation-source prohibition instead failed the limited execution-prohibition branch, with no precise explanation of the missing evidence. Relabeling or merging an earlier source clause after clarification could also hide the duty from a check based only on current field labels.

The native browser already enforces a document source policy and retains requested/final document URLs. Its records do not yet provide a complete, attributed, policy-bound route history. In particular, this review found no implemented `didReceiveServerRedirectForProvisionalNavigation` callback. This source observation does not establish WebKit's complete redirect behavior or prove that adding that callback alone would enforce every request before it is sent.

## Source repair

[Source requirements](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserSourceRequirements.swift) now expose the navigation-history duty derived from their current and retained historical origin constraints. They also map that duty to the current requirement IDs, including a mixed row that contains an earlier source span after resegmentation. The mapping does not claim the row has no other obligations.

[Assessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) reports `navigationHistoryUnverified` for those rows. That status precedes page-semantic interpretation and answer-source permission. Unresolved source syntax still remains uncompiled, and host-bound literal clarification parameters keep their typed treatment. Assessment context uses version 6 for navigation-source fields or the new history status; version 5 remains the answer-source-only case.

[Answer eligibility](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchAnswer.swift) withholds the page's answer options while a navigation-history duty exists. This check applies before composing current or recalled reading options. The generic source-field success shortcut is removed. An already matched answer-source clause continues through its separate native-origin check.

[Link-planner instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserLinkPlanner.swift) explain the missing history and prohibit inferring completion from visited-site labels, a new policy or manual login handoff. Repeating a search or asking an unrelated question cannot manufacture the missing evidence.

This is a repair to false completion. **It does not yet enable completed answers for tasks with navigation-source restrictions.** Such tasks may continue gathering evidence, but remain open until a qualified native route-history mechanism exists. Existing navigation enforcement and login controls are unchanged; no new model call, polling loop, browser activity or stored private URL data is introduced by this patch.

## Prepared coverage and allowed checks

Seven methods are authored and unrun:

- Four in [ResearchAnswerTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift) cover a source condition under both loose and matching configured navigation policies, a source prohibition with the precise history status, independent answer/navigation restrictions, and a real owner clarification followed by complete relabeling of the original turn. In the last fixture, even a positive candidate review and permitted answer source cannot remove the retained navigation duty; the search is not repeated.
- Three in [SourceRequirementsTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSourceRequirementsTests.swift) cover allow lists and exclusions, historical obligations mapped through resegmentation, and the absence of navigation duties for answer-source-only or ordinary research goals.

Six changed Swift files passed `swiftc -frontend -parse`. Reviewed source inventories select 1607 default / 924 focused methods, seven additions each and no removed or renamed identifiers. No JavaScript changed. These checks establish syntax and source-inventory consistency only; they are not compilation, assertion results or live qualification.

## Native history repair sequence

The following work remains open in [TODO](../../../TODO.md). A positive completion path must satisfy these requirements before replacing the conservative gate:

1. **Define what the source restriction covers.** Current policies constrain top-level document origins, not all subresources or network traffic. Do not silently claim network isolation. Explicit all-request restrictions need a separately supported enforcement mechanism or an honest unsupported result.
2. **Retain native action attribution.** Bind an immutable record to the task root, browser context/session, operation ID, document generation and policy active at dispatch. Record native attempts separately from successful receipts. A cancelled callback, denied route or missing receipt must not erase an attempt or establish that nothing happened.
3. **Record the route at native boundaries.** Reconcile requested destinations, allowed main-frame actions, redirects, response URLs and committed documents. Validate the actual platform callback ordering before claiming complete coverage. If an origin can be reached without a trustworthy observation, keep the route unverified; observing a redirect after dispatch does not prove it was prevented.
4. **Account for nonordinary navigation.** Handle exact cached/Instant Back restoration, scripted navigation, form-triggered navigation, failures and WebContent termination. Source checks on the final page alone do not cover these paths. Unexpected active navigation must be attributed or retain an explicit unknown-history condition.
5. **Separate manual login from automation.** Manual activity in the main browser or sign-in window remains user activity. Preserve pause/handback ownership epochs and native document identity. Handback can authorize fresh observation; it cannot rewrite earlier automated history, turn a human login into an automated navigation receipt or hide an unattributed transition.
6. **Preserve policy lineage across answers.** Retain which policy governed each action and how its goal revision relates to the current root. A newly installed policy cannot retrospectively certify older work. Distinguish an unchanged source scope after an unrelated clarification, explicit user replacement and correction of a prior model interpretation; ambiguous changes remain unresolved.
7. **Reconcile owner and browser histories.** Cross-check the owner's confirmed visits against the native attempt and receipt records. Cover direct native operations and active observations as well as journaled search, links, forms and revisits. Missing operations or bounded-history overflow must not look like a complete empty history.
8. **Bind completion to the latest complete history.** Carry sealed evidence into assessment and answer admission, revalidate it immediately before delivery, and include its identity in any retained-reading/completion contract. A previously eligible reading must not survive a later violating or unknown visit. Source compliance must not discharge offer identity, dates, prices, availability or unrelated prohibitions.
9. **Qualify before enabling the positive path.** Author deterministic cases for redirects through excluded origins, identical final URLs with different routes, cache restoration, cancellation, policy changes, manually performed login and unowned navigation. Run those and the native callback-order checks only after execution permission resumes, then schedule the separately authorized real-site scenarios. Preserve failures and uncertainty.

Broader criterion replacement, form/account recovery, actual-model comparisons and the 8 GB resource target remain open. The RTX 3080 desktop authorization remains recorded in the main tracker; no inference or SSH retry occurred in this repair.
