# Keep page acceptance and task adoption separate

Source checkpoint: 2026-09-09. Parent: `25a5b2e`. Source repair and prepared regression coverage only. Builds, typechecking, assertions, inference and browser execution remain paused.

## First-principles finding

The [navigation-episode review](BROWSER_NAVIGATION_EPISODE_RECONCILIATION_REVIEW.md) distinguishes exact callback objects from weak policy/URL associations and native navigation receipts. A finished callback still does not establish that the browser accepted its page as an observation. Likewise, an accepted observation is not a current task document: it may need explicit handback, fail identity validation, be superseded, or transfer to a different task.

The native browser already made these distinctions in live state. Its history did not retain the transitions. Inferring them later from a finished callback, an open action gate, or a native handback return could manufacture an acceptance or adoption that never happened.

## Native records

[OwnedBrowser](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) now retains an immutable identity for each accepted candidate. It binds the original task, parent browser session, ownership epoch, generation, canonical origin, observation source and explicit-handback requirement. A completed navigation retains its actual observed-navigation correlation ID. A same-document candidate retains that distinct basis and no invented navigation-object ID; its existing DOM identity check still happens during adoption.

Two events are recorded at their actual transitions:

- `accepted`: after the validated navigation or same-document candidate is stored in the existing active/user observation slot.
- `adopted`: after the existing identity, ownership, presentation and cancellation checks, claim and document assignment have succeeded. This event retains the original candidate and the actual adopted source.

Native handback passes its own operation ID into adoption. Ordinary active-page acquisition has no native handback ID. A load that starts during automation and finishes while paused keeps its active observation source and its explicit-handback requirement. No additional action-gate call, DOM read, navigation, await or permission transition was added.

If adoption itself claims the candidate for another task, the new history retains adoption with the old candidate's task/epoch/generation. It does not invent an acceptance event in the new claim. Existing claim/discard gaps remain visible.

Page-observation events have a 128-record bound and an explicit overflow marker. Each omitted event still advances the frozen-history identity, including an adoption after the buffer is full. Shared retained ordinals now cover at most 960 entries across all record kinds. The native history identity is version 6. Full URLs remain private live state; these records retain canonical origins, and their descriptions omit IDs and location data.

## Reconciliation and projection

[ResultAssessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) version 11 pairs accepted navigation candidates with valid exact observed callback episodes. `matched_observed_admission_count` means the native acceptance occurred after its matching finished callback, not that an automated action, actor identity, authentication or whole-route compliance was verified. Legacy response association remains an explicit gap.

The separate `page_observations` projection counts retained acceptances, adoptions, exact matched adoptions, adoptions linked to native handback and same-document candidates. It detects absent or mismatched acceptance, duplicate events, changed claims, invalid bindings, a missing required handback and incomplete native operation pairs. A native handback can adopt a page and subsequently fail: the adoption remains a fact, and linking it to that failed native attempt never means successful authentication or outer workflow Resume.

Unadopted candidates are historical records, not claims that a page remains current or that every observed page needs adoption. Same-document source lineage stays unqualified even when the existing DOM identity check allowed adoption. Reconciliation exports only counts and gap names. [Planner instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserLinkPlanner.swift) explain these limits. The [navigation-source completion gate](BROWSER_NAVIGATION_SOURCE_COMPLETION_GATE_REVIEW.md) remains active.

## Prepared coverage and allowed checks

Two new methods in [OwnedBrowserTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseOwnedBrowserTests.swift) cover transfer to another task without fabricated acceptance and bounded history whose omitted adoptions still invalidate snapshots. Existing same-document handback, interrupted observation, successful/failed handback and [scripted navigation](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSourcePolicyTests.swift) scenarios now assert acceptance/adoption identity, control provenance and the absence of fake navigation receipts. The scripted case also checks projection privacy. [ResearchAnswerTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift) retain the route-completion hold with version 11, including empty page-observation history for an ordinary automated load.

Six changed Swift files pass parse-only syntax checking. The new repeated-history fixture script passes `node --check` through stdin without execution or a scratch file. Default/focused source inventories select 1635 / 952 methods: exactly two additions, with no methods removed or renamed. These are syntax and source checks, not compilation or passing assertions. No app/browser run, inference, SSH retry, push or installed-app replacement occurred.

## Remaining work

Follow-up: [observation disposition history](BROWSER_OBSERVATION_DISPOSITION_REVIEW.md) now records why tracked loads end and why accepted candidates are retired. It distinguishes these native transitions from finished callbacks, adoption and network-cancellation proof.

Recorded native admission/adoption is now available for continued reconciliation. Full claim/retirement timelines, source-policy and goal lineage through manual login, complete control intervals and qualified response/redirect/platform coverage remain open. Native observed-page adoption still does not establish successful login or the correct continuation of the parent research/form task. Continue those repairs and the deferred qualification scenarios in the [checklist](../../../TODO.md).

Transfer of an already current document through `acquireCurrentDocument` still has claim-boundary evidence only; that path did not accept or adopt a new observation. Rejected loads and superseded candidates also need their appropriate temporal treatment, without treating every unadopted historical candidate as a current failure.
