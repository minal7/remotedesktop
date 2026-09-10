# Recover unused form intentions after a same-document rebuild

Source checkpoint: 2026-09-09. Parent: `7870e82`. Source repair and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

A website can replace its form or input elements after manual sign-in without replacing the browser document. Native document identity alone therefore cannot decide whether an unused form preparation still describes the available controls. The earlier [unused edit-precondition repair](BROWSER_UNUSED_PRECONDITION_HANDOFF_REVIEW.md) permitted fresh preparation only after a different document, leaving this same-document case stranded.

The distinction remains between an unused intention and an outstanding duty or effect. An initial default captured solely as an edit precondition is not a promised value, verified criterion or input receipt. It can be discarded before fresh preparation when the old adapter is permanently retired. Preservation/read duties, earlier stages, attempted actions, exported capabilities and uncertain effects cannot be discarded on that basis.

## Native structure at handback

The [unused-intent record](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormPreparation.swift) now distinguishes `document_changed` and `form_structure_changed`. Its host-side structure contains only the visible projected native control IDs grouped by native form ID. It excludes labels, values, URLs and semantic associations. Missing control metadata or a truncated snapshot cannot establish this structure. Unavailable private values are a separate condition and do not by themselves make metadata incomplete.

For same-document recovery, the selected original form must have a nonempty native membership set and its current membership must differ. Replacing the form, replacing an input or changing the visible membership can meet this structural condition. A label or value change alone cannot. This does not prove physical removal of every original DOM object, equivalence of fields, successful authentication or an account identity.

The [research owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) retains the complete projected form structure during successful explicit Resume, under the existing task, session, ownership and cancellation checks. Recovery takes another fresh owned observation, enforces current source policy and requires the same native document checked at handback. A same-document structural change must match that handback structure exactly. A form rebuilt after handback needs another explicit handback; an earlier observation cannot authorize it.

After native page validation and callback joining, the owner rechecks the current goal, preparation identity, Pause/retirement state and handback record before retiring the adapter. It records the original purposes and actual observation status, then clears the unused preparation. Fresh complete-goal action planning, scope review and native field preparation follow. Old defaults and control bindings are not transferred. Retirement creates no input, receipt, verified stage or task-completion evidence.

The existing unused-preparation eligibility rules remain mandatory. Unknown or pending reads, retained criteria, preservation/read obligations, revisions and used adapters stay with their existing recovery paths. Earlier stages and uncertain effects retain their history.

## Planning context

[Action context](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) version 31 adds `retirement_reason` to the existing `unused_form_intent_history` entries. The context distinguishes unobserved preparations from captured initial edit preconditions without exposing their private values or native identities. Instructions require fresh review of every outstanding requirement. Historical page labels remain untrusted data.

When date-replacement metadata is also present, the combined context retains version 31 and both fields. Date-only contexts keep version 30. No response schema shape or action authority is added.

## Authored verification, unrun

Four new methods in the [preservation suite](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift) specify:

- Replacement of an entire form or one input, each before or after initial private-field capture: fresh defaults and native targets, rejection of the old proposal, unchanged complete goal, no initial-search replay and only the first actual input stage entering confirmed history.
- Replacement after handback withholding retirement until another explicit Pause/Resume.
- Value-only changes retaining the pending preparation without an unused-intent release or input dispatch.
- Complete metadata requirements and native membership comparison, including labels and unavailable private values not changing the structure.

An existing preservation-duty case now also attempts this recovery after an original field is replaced and requires its preparation and duties to remain. Existing different-document context assertions use version 31.

Four changed Swift files pass parse-only checks. Four new fixture scripts pass `node --check` without execution. Default/focused source inventories select 1773 / 1090 methods, with four additions and no removals. These establish syntax and source registration only; no assertion, native timing, provider behavior or model decision is qualified.

## Remaining repair order

1. Reconcile preserved values, prior criteria and uncertain actions through account/document transitions. Matching visible structure does not supply those proofs.
2. Address semantic changes that retain the same native membership, including changed field kinds, constraints or meaning. This repair does not implement generic criterion correction.
3. Qualify native replacement timing, cancellation/reentrancy, host/phone handback, login providers and browser lifecycle behavior when execution is authorized.
4. Continue complete goal interpretation, result verification and durable process recovery in the [repair checklist](../../../TODO.md). The global navigation-source completion restriction remains active. Real travel/concert/movie tests require later explicit permission; model replacement/adaptation, RTX 3080 work and 8 GB resource qualification remain deferred.

No SSH retry, model run, installed-app replacement, push or generated-file cleanup occurred here.
