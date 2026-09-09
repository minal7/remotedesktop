# Preservation duties from unfinished form reviews

Status: source repair for retaining accepted preservation decisions during revised preparation review. Assertion execution, native behavior and model qualification remain pending.

Follow-up: [separate form-state verification](BROWSER_FORM_STATE_VERIFICATION_REVIEW.md) adds a native/host no-input proof foundation. Parent-stage and query integration remain pending.

## First principles

A review can identify a control that must remain unchanged before it has decided how to complete the form. A subsequent question, cancellation or failed page check must not erase that duty. However, identifying a duty is not observing its value, validating the current page or authorizing an edit. The application must retain the source purpose separately from those later proofs.

Previously, newly selected preservation stayed in local review-loop state until a complete revised action was applied. An unfinished loop could lose the selected control and its original user-source span. A later interpretation could then omit that obligation or replace its purpose with a different fragment of the conversation.

## Source repair

[The owner review loop](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) now retains accepted preservation immediately after checking the current task and validated proposal, before the next cancellable page check. It covers both explicit `preserve_controls` decisions and preservation supplied with a form selection. Other intermediate review decisions do not automatically become preservation duties. Raw or invalid replies grant no obligation or effect authority.

[Preparation review context](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormPreparation.swift) adds these duties transactionally. It requires the exact current review context and selected form, retains existing sources, validates exact source references and roles, binds the observed control metadata, and keeps the existing limit of 16 preserved controls. A stale proposal cannot update a newer context. Accepted additions invalidate a cached revised action. Retrying review or reviewing a further answer seeds the form scope with the retained duties; the remaining field and metadata decisions still need review.

The preparation frame keeps its original completed-review context immutable and maintains subsequent review duties separately. The [version-2 preparation baseline](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormPreparation.swift) binds both contexts while retaining its original captured fields and prior receipts. This separation matters when a later answer supplied a duty that did not exist in the original interpretation: that duty cannot be projected backward as an earlier observation. [Form input](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) carries the exact retained preservation sources into the revised input rather than recreating them from a newly grouped requirement.

[Planner instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) explain that retained preservation can come from an unfinished review, and that its presence proves neither an observed value nor a completed edit review. The existing version-19 action context shape is unchanged. No private field observation, input event or query is added when a semantic duty is retained. Original value capture, current native binding, preservation checks and executable-input validation remain separate.

## Prepared coverage and source checks

Eight methods were added to [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift). They cover:

- A preservation decision followed by a question, another answer and a differently segmented interpretation, retaining the original source through execution preparation.
- Cancellation during the page check immediately after the decision, before the whole review is complete.
- Unavailable and failed planner outcomes, and the shared review deadline, retaining accepted duties for retry.
- Invalid preservation references adding no duty; stale contexts rejecting reuse; later duties not claiming an earlier-goal observation.
- A replaced control after a partial review preventing a new baseline.
- Preservation supplied through form selection surviving an unfinished review without granting an edit.

The authored Notes fixture deliberately models an initial missed preservation decision before any input event, so the later review must carry the newly recognized duty. It is fixture semantics, not evidence of actual model behavior. A shared setup replaces duplicated fixture preparation. An asynchronous assertion expression was corrected during source review; parse-only validation cannot substitute for later typechecking.

Five changed Swift files passed `swiftc -frontend -parse` only. The assembled DOM, five embedded fragments and 18 distinct literal fixture scripts/snippets passed `node --check` only. The [default inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,425** source methods and the [focused inventory](browser-control-state-inventory.json) selects **742**, adding eight identifiers and removing none. Documentation targets and whitespace are checked.

No build, typecheck, assertion execution, app/browser/computer-use launch, inference, SSH retry, held-out inspection, push or installed-app replacement occurred. No scratch artifact was retained. The prepared deadline case has not run. These checks prove source syntax and inventory correspondence, not functional correctness.

## Remaining repair sequence

1. Handle revisions that require no edit and work explicitly superseded by later user instructions. Do not manufacture an input event to obtain a query receipt, silently drop obligations, or force abandonment of the whole request to fit an obsolete plan.
2. Account for when preservation was first observed. A duty retained before private capture cannot prove an unobserved earlier interval. Obligations discovered after earlier effects need explicit reconciliation; current values alone cannot establish that those earlier effects left them unchanged.
3. Continue changed-control/document reconstruction, task and process recovery, account-login handoff, broader criterion lifetimes and independent result verification. These contexts are retained in the live task; this repair does not provide process recovery or replace native identity checks with label matching.
4. Qualify real travel/concert/movie workflows and actual lightweight models after explicit execution permission. Alternate-model selection and authorized RTX 3080 adaptation remain available after measured failures. Performance work remains deferred. Continue the full [repair TODO](../../../TODO.md).
