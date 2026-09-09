# Keep callback episodes distinct from native document acceptance

Source checkpoint: 2026-09-09. Parent: `aea5a84`. Source repair and extended regression coverage only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

[Control reconciliation](BROWSER_CONTROL_EPISODE_RECONCILIATION_REVIEW.md) can distinguish a native handback return from owner Resume without establishing which navigation produced a document. Likewise, a `didFinish` callback is not interchangeable with a native accepted receipt. Cached Back/Forward restores can have different callbacks from a normal load, and a scripted navigation can have callbacks without being an automated dispatch.

The native log retained exact callback references and slot associations but represented every accepted document with the same terminal outcome. It did not retain the acceptance basis, the origin of the successful response associated with the pending slot, or WebKit's Instant Back flag. A later checker would otherwise have to guess which proof path produced the receipt.

## Native evidence changes

[ComputerUseOwnedBrowser](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) now records three native commit bases: response plus finish, exact current history item plus finish, or the dedicated Instant Back history-item path. Failure retains no commit basis or committed-response origin.

The pending navigation retains its actual successful response URL instead of only a Boolean; the existing Boolean check is derived from its presence. The response delegate already requires a non-nil validated response URL, so this preserves admission behavior. Only its canonical origin enters committed history, never its path, query or fragment. This remains a pending-slot response association, not an exact `WKNavigation` response proof.

At `didFinish`, the existing history-item predicate is evaluated after ownership/generation validation even when a response was also delivered. When it holds, the receipt retains that stronger history-item basis. The acceptance condition remains response OR exact history item. This avoids classifying a cached traversal as an ordinary callback sequence just because WebKit also supplied a response. The dedicated Instant Back path retains its own existing approval and current-item checks.

History-policy observations now retain the actual `willUseInstantBack` flag only for the history-request phase. An exact history-item association is still different from an exact navigation-object association. The history identity uses version 5. No new action-gate query, navigation, model call or control transition was added.

## Episode reconciliation

[ResultAssessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) version 10 groups main-document callbacks only by recorded exact native navigation-object identity. It checks consistent attempt/session/ownership/generation bindings, phase multiplicity and order. Slot-only action/response/URL callbacks are not upgraded into exact episode members. Child sign-in observations remain in the separate window-lifetime assessment.

Native committed attempts require the recorded acceptance basis and its matching evidence. Ordinary commits need a consistent exact finished callback sequence. History-item commits check their earlier committed source in the same native session/ownership epoch; a dedicated Instant Back commit also needs its exact allowed history-item observation with the Instant Back flag. The checker can account for cached paths without inventing ordinary load callbacks. A native failure can close its identified episode even when a later cancellation callback no longer has the pending reference.

Counts distinguish dispatch episodes, unrequested/scripted episodes, observed finished callbacks, matched native commits, commits admitted on history-item evidence and redirect callbacks. Missing/foreign bindings, duplicate or unordered phases, unfinished episodes, missing commit bases/origins, missing history sources and absent Instant Back evidence remain explicit gaps. Reused operation text cannot merge native identities across claims.

Several limits remain deliberate:

- A successful response origin does not make its pending-slot association exact. Matching response and committed origins is consistency evidence only.
- A redirect callback's live WebView URL is not the next destination request. Redirect-destination qualification remains open.
- A finished unrequested callback does not prove that its page was accepted as an observation, adopted after handback, or initiated by a person rather than a script. Observed-page admission remains a separate gap.
- A process-termination callback cannot be assigned to a navigation object it did not supply.
- A matched native commit does not establish whole-route/source compliance or platform callback coverage.

The frozen projection exports counts and gap names, not native IDs or URL/origin data. [Planner instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserLinkPlanner.swift) explain these distinctions. The [navigation-source completion gate](BROWSER_NAVIGATION_SOURCE_COMPLETION_GATE_REVIEW.md) remains active.

## Prepared coverage and allowed checks

Seven existing scenarios gain assertions, all unrun:

- [SourcePolicyTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSourcePolicyTests.swift): ordinary exact callbacks retain their commit basis; redirects retain the actual response origin without inventing redirect destinations; scripted navigation stays separate; a held/cancelled load changes from an unfinished episode to a native failure without a fake finish; and reused operation names after Stop/reclaim remain separate callback episodes.
- [ResearchHistoryTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchHistoryTests.swift): Back/Forward and explicit evicted-page GET retain distinct evidence, including the native Instant Back flag when that path is used.
- [ResearchAnswerTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift): matched callback/native-commit evidence still leaves response association and platform qualification open. Existing projection privacy checks include the nested episode diagnostic. Two diagnostic-version expectations are updated.

The held-load fixture now waits for its exact provisional-start record before checking the pending episode. No JavaScript changed. Six changed Swift files passed `swiftc -frontend -parse`. Source inventories remain 1633 default / 950 focused methods, with no added, removed or renamed identifiers. These are syntax and source-inventory checks, not compilation or passing assertions. No app/browser execution, inference, SSH retry, push or installed-app replacement occurred.

## Remaining repair order

Follow-up: [page-observation history](BROWSER_PAGE_OBSERVATION_HISTORY_REVIEW.md) now records native candidate acceptance and adoption, pairs accepted navigation candidates with exact callbacks and retains native handback links. Full control intervals, claim/source lineage and platform qualification remain open.

1. Retain and reconcile actual admission/adoption of unrequested or same-document page observations, then join navigation episodes to recorded control intervals without inferring actor identity from the action gate.
2. Give claim/retirement and workflow scopes precise temporal semantics and reconcile source-policy/goal lineage through manual login and legitimate clarification/replacement.
3. Qualify supported macOS/WebKit callback coverage, response association and redirect behavior before issuing affirmative route evidence. The current counters cannot substitute for that qualification.
4. Continue account/document/form recovery, criterion replacement and semantic/model qualification in the [repair checklist](../../../TODO.md). Live travel, concert and movie scenarios and resource measurements remain deferred to explicit execution permission.
