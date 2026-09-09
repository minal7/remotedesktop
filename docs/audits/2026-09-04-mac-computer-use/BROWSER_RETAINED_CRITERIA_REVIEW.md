# Verified retain eligibility and source continuity

Source checkpoint: 2026-09-09. Parent: `23de7b8`. Source repair and prepared regressions; compilation, assertion execution and model qualification remain paused.

## First-principles findings

Retaining an already verified criterion is different from keeping an arbitrary captured field unchanged. A captured invariant says the app must not change that value; it does not establish that the value satisfies a requested criterion. Earlier revised preparation can leave captured, deferred fields in a continuation's `finalValues` without putting them in `verifiedTargetIDs`.

The old retain eligibility used the broader final-value set. That could offer a captured invariant as if it had already been verified for the task. The form-input guard repeated the same overly broad check. Separately, the current review could attach a new user requirement to a retained criterion, but completed continuation construction copied only its earlier sources and ignored the current retain purpose. Neither error requires a model failure: they are host-side distinctions the application must preserve.

These are prerequisites for a form stage consisting only of retain operations. Such a stage remains unimplemented. This checkpoint repairs the existing mixed edit/retain path before extending it.

## Source repair

[Action input](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) now offers retain only for controls in the previous continuation's verified target set whose current value has not been marked changed. The broader final-value set still determines inherited obligations and required controls. Captured invariants therefore remain protected without being promoted into verified criteria. They can receive a separately justified edit/desired-value verification through the existing planning path.

[Form input](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) independently requires each retain intent to name a previously verified target with nonempty original source purposes and the exact earlier desired value in the current captured evidence. A missing origin or changed value rejects. The input's new `retainedFieldSources` merges the earlier verification sources with the current reviewed retain requirements, deduplicating exact source records. It leaves the fields outside `editableFieldAliases`.

Form context/schema version 15 exposes `retained_criteria` with those exact source purposes and current field aliases. It does not expose hidden field values or grant input authority. [Planner instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormPlanner.swift) explain that retained criteria remain obligations, that captured invariants do not imply verification, and that retaining does not call for an additional edit. Contexts without retain intents keep their earlier version selection.

[Continuation construction](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) carries the retained sources into `verifiedSources`, after checking the original verified target and disjointness from this stage's new input/observation criteria. It preserves earlier `editedSources`, actual input IDs and native observation origins. A current retain instruction is not rewritten into history as an input that happened earlier. Version-8 continuation identity distinguishes this source-continuity behavior; the contract already binds the exact v15 planning input.

The same merge applies to a full stage, retained input prefix, observed-only prefix, or recovered full input history. Existing native value, receipt/origin, object and preservation checks still precede publication. An unexecuted or rejected new stage cannot publish its retain purposes as completed work. Retained criteria remain inherited text-contract invariants and query requirements.

Source provenance is not semantic correctness. The model still has to associate the user's current requirement with the right native field and determine whether retaining the earlier value remains appropriate. The application now preserves that decision's sources rather than dropping them; it does not claim the decision is independently correct.

## Prepared coverage and limited checks

Six new methods in [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift) cover:

1. An earlier City input followed by a location answer confirming Seattle: the current retain source survives later Query/Category input and query preparation, with no second City input.
2. Earlier actual-input sources and operation IDs remain unchanged while the newer retain source survives and deduplicates in another review.
3. The source survives partial input recovery alongside a separate unsent Category entry.
4. A criterion originally verified without input retains its native proof origin and does not become an input record.
5. A changed retained City value prevents publication and further input.
6. A captured, deferred Query invariant is neither offered nor decoded as a verified retain criterion; Category remains eligible because it was actually verified.

The source-continuity fixture keeps the original request and adds a scoped `Seattle.` answer. Its next review cites that answer as the City retain purpose, while later inputs use original source text. Context and request assertions cover v15. These are authored planner decisions; no local model or runtime assertions ran.

Five changed Swift files passed `swiftc -frontend -parse` only. The assembled DOM, five embedded fragments and 36 distinct fixture scripts/snippets passed `node --check` only, including the new conditional City handler. The [default inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,494** source methods; the [focused inventory](browser-control-state-inventory.json) selects **811**, adding six identifiers and removing none. Documentation targets and whitespace were checked. Syntax and source correspondence do not establish type correctness or passing behavior.

No build, typecheck, assertion execution, inference, app/browser/computer-use launch, SSH retry, held-out inspection, push or installed-app replacement occurred. No scratch artifact was retained.

## Remaining sequence

1. Add a dedicated read-only execution path for a completed retain-only review. It must retain original native origins, expected values, current source purposes, preservation and cancellation ownership without compiling a dummy text edit or inventing an input receipt. The current form gate still requires an edit intent and the form proposal still requires nonempty edits.
2. Handle explicit supersession and changed goals without dropping pending work or uncertainty. Distinguish retained criteria, newly requested desired values and captured invariants throughout preparation and later stages.
3. Continue uncertain native tails, document/process recovery, preservation timing, dependent controls, account/login handoff and independent whole-task/result verification in the [repair TODO](../../../TODO.md).
4. After explicit execution permission, compile/run prepared coverage and qualify actual lightweight models and real travel/concert/movie workflows. The 8 GB Mac and resource targets remain unverified. Alternative models and RTX 3080 adaptation remain authorized after measured model failures and verified remote access.
