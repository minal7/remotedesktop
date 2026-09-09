# Read-only retain stages beneath the research goal

Source checkpoint: 2026-09-09. Parent: `91fc5a5`. Implementation and prepared regressions only; compilation, test assertions, model inference and live qualification remain paused.

## First-principles distinction

A current review can decide that earlier verified search criteria should remain in force. That decision does not call for another input event, nor does it establish a new desired value from a model payload. The old action gate required an edit intent, the form input required an editable alias, and the form proposal accepted only nonempty edits. The execution owner then required a text contract. Together these assumptions left no honest representation for a completed retain-only review.

Allowing an empty text contract or inserting a dummy edit would blur three different facts: an input happened, a desired value was verified without input, and an earlier verified criterion was retained under the current request. This change gives the third case its own execution path. Original native input receipts and observation proofs remain the authority for the earlier criteria; fresh validation establishes the point-in-time state for publishing the retention review.

## Source implementation

[Action planning](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) can now release a fully reviewed form scope containing retain intents and no edit intents. This requires an earlier verified continuation with no pending edits and no changed criteria. The prior [retain-eligibility repair](BROWSER_RETAINED_CRITERIA_REVIEW.md) still limits retain to unchanged previously verified controls. All remaining control metadata and preservation duties still require review. An empty, all-unrelated or preservation-only scope does not become executable.

[Form input](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) permits an empty editable-alias set only with nonempty retained sources and no unfinished earlier edits. Changed criteria must still be editable repairs, so they reject this path. Version 16 exposes `retain_only=true`. The [planner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormPlanner.swift) offers only `retain=true`, a scoped question, or unavailable for such an input. Its emitted schema has no empty edit-target enum. The [strict proposal decoder](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormProposal.swift) rejects false retention, extra keys, empty edits, preservation additions and resumption mappings on this alternative. Retention is not unavailable, and it compiles no text contract. Current reviewed preservation is carried automatically.

A class-bound `ComputerUseBrowserFormStage` interface lets the [owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift), [preparation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormPreparation.swift), action input and [query navigation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormNavigation.swift) retain either input execution or read-only retention. The existing physical-input class keeps its nonoptional contract and its journals, leases, operation identities, prefix retirement and reconciliation. Query navigation binds the selected stage's digest rather than assuming that every stage owns a text contract.

The new `ComputerUseBrowserRetainedFormStage` in [FormStage](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) is retained by the owner before native awaits. Its identity binds the task, stage sequence, complete current planning context, previous continuation, reviewed scope, exact prepared native requirements, preservation and preparation baseline. It creates no text contract, physical operation ID or input journal. A read-only validation has no input uncertainty to recover by replay, tombstone or revocation.

Execution revalidates the original preparation and native field bindings, constructs candidate obligations, observes the original document, and invokes existing native requirement inspection. Publication requires unchanged criteria, original receipt/proof origins, exact actual-input history, captured invariant values, explicit preservation and current ownership. Candidate construction alone supplies no completed stage. The continuation and receipt are published together after the native and cancellation checks.

The continuation preserves prior actual-input IDs, input sources, edited/verified target sets and original observation proofs. It carries current retained sources, current explicit preservation and all captured invariant fields. Captured fields do not become verified task criteria. Stage and sequence limits remain bounded. The receipt records `retainedCriterionCount` separately from actual input and new no-input verification, both of which are zero for this stage. A completed receipt is historical review evidence; later action inspection and query preparation must validate current values again.

Action context/schema version 22 reports retention counts and per-criterion original input/observation provenance. It preserves earlier repair-at-publication history when present. Instructions distinguish these counts and require the next step to advance the remaining task rather than repeat retention to create history. The [driver](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift) uses the existing preparation/proposal/execution flow; its status text now describes form criteria so it also fits retention.

## Cancellation, recovery and limits

Pause during native validation prevents publication. The stage joins outstanding DOM completion before releasing ownership. Explicit handback can resume the same immutable review, repeating fresh read-only validation without another input or a cached callback being treated as current success. Repeating an already completed request returns its original historical receipt and does not append another stage.

Input-prefix/full-history recovery and unsent-input retirement return no result for a retention stage. They cannot discard newly accepted preservation or fabricate an input suffix. If a criterion changes before the retention stage publishes, the pending review remains held and cannot silently adopt the new value. Restoring the original state permits fresh validation; deliberate replanning/supersession of that pending review is still future work. A criterion that changes after a completed retention stage can use the existing fresh repair path.

Losing the native document, ledger, original object or observation origin prevents publication. This change does not add process/disk reconstruction. Source references still do not prove that the model associated a user's requirement with the right field or that retaining the old value remains semantically appropriate. Deferred fields remain unresolved, and neither this receipt nor a successful query verifies provider results or whole-task completion.

## Prepared coverage and allowed checks

Nine new methods in [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift) prepare coverage for:

1. A distinct retention proposal/schema and absence of any text contract, with strict rejection of incompatible alternatives.
2. Retention followed by a real native fixture GET after either actual input or no-input verification; separate counts, repeated-request identity and no retention journal writes.
3. A new accepted location answer surviving retention and later preparation without rewriting earlier actual-input history or proof origins.
4. Pause at native field binding and requirement-inspection boundaries, refused progress before handback, fresh validation afterward and no new input or journal write.
5. Changed desired values, changed readonly preservation and replaced objects withholding publication.
6. Lost native ledgers refusing both input-origin and observation-origin reconstruction from equal values.
7. A later changed criterion being repaired through the retained stage into a verified query.
8. An unfinished physical-input suffix preventing retain-only release or query authority.
9. Driver continuation from a prepared retain-only stage through the native fixture query.

These are authored planner decisions and unrun assertions. Existing initial all-unrelated/no-edit and invented-retain rejection cases remain applicable. Ten changed Swift files were syntax-parsed only; the assembled DOM, five fragments and 37 distinct fixture scripts/snippets passed JavaScript syntax checks only. The source inventories select **1,503 default** and **820 focused** methods, adding nine and removing none. Documentation targets and whitespace were checked. These checks establish neither Swift type correctness nor passing runtime behavior.

No build, typecheck, assertion execution, inference, app/browser/computer-use launch, SSH retry, held-out inspection, push or installed-app replacement occurred. No scratch artifact was retained.

## Remaining sequence

1. Add explicit supersession/replanning of pending reviews and changed goals while retaining source purposes, original preservation and every uncertainty obligation. In particular, a changed criterion before retain-only publication cannot yet become a new reviewed repair stage automatically.
2. Continue uncertain native input tails, document/process recovery, dependent controls, preservation timing and semantic pending-field mapping. Do not reinterpret a matching value or retention receipt as original operation evidence.
3. Finish account/login handoff and independent whole-task/result verification in the [repair TODO](../../../TODO.md).
4. After explicit execution permission, compile and execute prepared coverage, then qualify actual lightweight models and bounded real travel/concert/movie scenarios. Model quality, 8 GB memory/resource targets and sustained fan behavior remain unverified. Alternative models and remote RTX 3080 adaptation remain options after measured failures and verified access.
