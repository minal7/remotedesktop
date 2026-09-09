# Verify leading matching criteria in mixed form stages

Status: source repair for a leading observation segment followed by input. Later conditional observation segments, compilation, assertions and model/native qualification remain pending.

## First principles and ordering

Skipping redundant input must respect the proposed order. If changing Country resets City, an initially matching City is not evidence about City after Country changes. Hoisting every initial match into an invariant before the first edit would impose a stronger requirement than the ordered plan and could prevent useful prefix recovery.

A leading run of matching criteria is different: it precedes every proposed input. Once freshly verified, those criteria become the same completed obligations that earlier verified edits would have established. They must remain correct while later steps execute. This repair handles that leading segment. It deliberately does not claim to finish the entire mixed-stage problem: a field after the first required input still follows the existing input transaction, even if its original value matched. That later position needs its own fresh decision and retained recovery state.

## Source repair

[FormExecutionPlan](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormProposal.swift) retains original proposal order, identifies only the leading exact-value matches and compiles a distinct input contract for the remaining edits. Its identity includes the original full contract and the selected observation plan, so it cannot reinterpret an older full-input journal. Every omitted leading target becomes an explicit invariant in the remaining input contract. The ordinary generic text engine and its dispatch receipts are unchanged. Plans with unresolved resumed work keep their existing input obligations.

FormStatePlan now supports an exact nonempty subset of requested targets. The version-2 subset digest binds those target IDs as well as the full original contract. Foreign or empty target sets reject. Full-form verification keeps its existing identity. Native verification still checks the complete captured baseline before issuing a proof for the selected desired values; selecting a subset does not authorize a new value observation or a different source purpose.

[ResearchFormStage](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) saves and confirms the new contract, captures the leading proof and validates it before the remaining input. It retains that proof across cancellation. A mixed stage reconstructed after an input attempt cannot recover the missing observation origin from current matching values. The live original stage can reconcile its retained input contract and native receipts. On full input completion, a fresh native inspection checks the observation origins, extended real-input ledger and current final values before publication; journal identity and durability are confirmed again.

Version-7 mixed continuations combine the observed leading criteria with exactly the completed input prefix. Source purposes, actual edited targets and actual input IDs remain distinct. The pending list comes only from the remaining input edits. Partial and complete receipts retain the original planned criterion count, while separately counting dispatched inputs and values verified without input. Suffix retirement uses the original input-operation IDs and native origin/preservation checks; it does not retire or remap the completed observation criteria.

The [existing action/query integration](BROWSER_FORM_STATE_INTEGRATION_REVIEW.md) consumes those distinctions. A complete mixed stage can offer an explicit query without generating an input receipt for its leading observations. A partial stage withholds query controls and asks for the unfinished entries; changed criteria remain repair obligations.

## Prepared coverage and source checks

Twelve methods were added to [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift). They cover ordered compilation, refusal to hoist a later initial match, subset binding, one or two leading observations followed by input, query preparation/navigation, cancellation at observation/input/final inspection, rejection of older journals, inability to reconstruct lost observation history after an input attempt, changed leading values, handler-induced invalidation, and partial-stage continuation with only the unfinished City entry pending. A preservation change during suffix retirement must still block it.

The authored fixture adds a City field and Seattle goal text for three-criterion stages. Query/category handlers make unexpected input invalidate preservation or an earlier criterion. During review, an older fixture bug was found: `categoryAlreadyMatches` had been inserted into an unrelated test body, outside its scope, while the intended factory ignored it. That interpolation now lives only in the factory and controls the actual initial selected option. The earlier syntax-only checks did not expose that type/scope error. Assertions remain unrun.

Three changed Swift files passed `swiftc -frontend -parse` only. The assembled DOM, five embedded fragments and 24 distinct literal fixture scripts/snippets passed `node --check` only. The [default inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,462** methods and the [focused inventory](browser-control-state-inventory.json) selects **779**, adding twelve identifiers and removing none. Documentation targets and whitespace are checked. These checks establish syntax and source correspondence, not type correctness or passing behavior.

No build, typecheck, assertion execution, app/browser/computer-use launch, inference, SSH retry, held-out inspection, push or installed-app replacement occurred. No scratch artifact was retained.

## Remaining repair sequence

The subsequent [ordered-checkpoint source repair](BROWSER_ORDERED_VALUE_CHECKPOINT_REVIEW.md) implements later matching decisions through native prefix revocation and fresh pending preparation. The account below remains the historical boundary of this leading-prefix checkpoint; execution is still pending.

1. Continue mixed stages with fresh decisions at later field positions. Do not classify a future field from its initial value. Retain the original target, desired source-bound value, completed criteria, exact current observation, selected input/observation branch and corresponding journal identity before any effect. Recover the same branch after cancellation; never replace an uncertain input with a later value observation. Preserve prefix recovery when an earlier edit changes a later field.
2. Handle prefixes consisting only of observations when later input becomes uncertain, retain-only scopes, and work explicitly superseded by later instructions. Preserve earlier purposes and uncertainty; do not fabricate an input to fit a receipt interface.
3. Continue preservation timing, dependent-control and document/process recovery, login/account handoff and independent whole-task/result verification in the full [repair TODO](../../../TODO.md).
4. Compile and run prepared coverage, then qualify actual lightweight models and real travel/concert/movie workflows after explicit execution permission. Alternative-model evaluation and authorized RTX 3080 adaptation remain available after measured failures; performance work remains deferred.
