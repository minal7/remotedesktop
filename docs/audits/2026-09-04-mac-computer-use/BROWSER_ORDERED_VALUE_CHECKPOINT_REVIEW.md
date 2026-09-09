# Ordered decisions for later matching form fields

Source checkpoint: 2026-09-09. Parent: `0b7caca`. Implementation and prepared regressions only; compilation, assertion execution and model/browser qualification remain paused.

## First-principles problem

A requested final value and evidence that input occurred are separate facts. A form should not send a redundant input event merely to fit an execution receipt. However, classifying every field from the initial page is also wrong: entering an earlier field may reset, populate or replace a later one. The decision belongs at the later field's ordered position, after earlier work has been verified.

The [leading-prefix repair](BROWSER_MIXED_FORM_PREFIX_REVIEW.md) handles matching criteria before any required input. This checkpoint extends the decision to later positions through the existing prefix-recovery protocol. It does not introduce a second input executor or let present values rewrite attempted history.

## Source repair and evidence boundaries

In [ResearchFormStage](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift), the reviewed research adapter checks the freshly read destination immediately before its native apply call. If a later replacement already has the exact desired bytes, it raises `valueCheckpointRequired` before sending input. This covers text and the existing native option-identity representation. The generic literal text executor remains unchanged. The gate only applies after a prior physical input step; leading matches already have the separate observation path.

The signal does not publish completion. The text engine retains its attempted/uncertain disk flags for that original operation. The [research driver](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift) routes the signal to existing prefix recovery, which requires the original native ledger and receipts, checks current required objects and preservation, proves the entire suffix unsent, revokes those exact operation IDs, and durably records the retained prefix and retirement. A published pending suffix therefore has native revocation behind it. A flag or matching value alone cannot supply that authority.

Fresh form preparation then retains earlier criteria and remaps every pending entry to a current source-bound proposal. [FormExecutionPlan and FormStatePlan](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormProposal.swift) now allow those explicitly mapped pending criteria to use their ordinary leading-state verification path. Native proof still checks the captured baseline, exact actual-input ledger, current options, original objects and preservation. An all-matching remainder can complete with zero additional inputs; a matching leading segment can precede the remainder's necessary input. The new stage's contract is saved and confirmed before proof publication.

The decoder continues to require every offered pending ID exactly once, distinct current proposed fields, complete reviewed edit scope and valid current payload sources. It rejects missing, duplicate and stale mappings. These are structural checks; they do not independently prove the model mapped the user's purpose to the semantically correct field. The [form planner instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormPlanner.swift) now explain that the executor may verify a proposed criterion without input while the planner must still provide the entire mapping and payload.

Completion also retains the pending entry's original source purposes alongside the new payload sources. Previously that merge happened only while carrying another unfinished entry. Both actual-input and observation completion now use the shared resolved sources. Carrying source history does not itself prove that every original task requirement is satisfied.

## Ordered cases

| Earlier event's effect on the later field | Required continuation |
| --- | --- |
| Initially matching and still matching | Stop before redundant input; prove/revoke the unsent suffix; freshly prepare and verify the desired criterion. |
| Initially different, now matching | The original precondition rejects; prefix recovery preserves earlier input; fresh preparation can select observation. |
| Initially matching, now different | The original precondition rejects; after recovery, fresh preparation proposes the necessary input. |
| Initially different and unchanged | Continue the original input transaction. |
| Native input was already attempted | Reconcile its original native receipt and outcome; do not run the new apply gate or convert the attempt into observation. |
| Preserved control changed, required object disappeared or ledger was lost | Withhold retirement/completion; matching destination bytes are insufficient. |

Changed earlier editable criteria can remain explicit repair obligations through prefix recovery. Their changed values cannot silently become a successful new baseline. Query controls stay withheld while pending work or required repairs remain.

## Prepared regressions and limited validation

Eight new methods in [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift) cover later matching choices, later matching text before remaining input, earlier handlers that populate/reset later fields, driver continuation, complete pending mappings, Pause during revocation or fresh verification, original uncertain-input reconciliation, and changed preservation/earlier criteria. The fixtures retain explicit query/navigation assertions and count actual native inputs separately from observations. They are authored decisions, not actual-model qualification.

The accepted-answer case in [FormPrefixTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormPrefixTests.swift) additionally checks that resolved sources retain both the original request and the current answer. Source review also corrected two previously committed test expressions from `.map(.property)` to Swift key paths. Syntax parsing alone had not detected those type-level mistakes.

Six changed Swift files passed `swiftc -frontend -parse` only. The assembled DOM, five embedded fragments and 32 distinct literal fixture scripts/snippets passed `node --check` only. The first extraction attempt stopped on an unresolved `categoryInputHandler` interpolation in the existing prefix fixture; the extraction was corrected to check that template and literal handler bodies separately. No JavaScript was evaluated.

The [default inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,470** source methods and the [focused inventory](browser-control-state-inventory.json) selects **787**: eight identifiers added, none removed. Documentation targets and whitespace were checked. These checks do not establish type correctness or passing behavior.

No build, typecheck, test assertion execution, model/inference run, app/browser/computer-use launch, SSH retry, held-out inspection, push or installed-app replacement occurred. About 85 GiB was available during the disk check. No scratch artifact was retained and no cleanup was necessary.

## Remaining work

The subsequent [observed-prefix recovery checkpoint](BROWSER_OBSERVED_PREFIX_RECOVERY_REVIEW.md) implements the source path for a leading observation followed by proven-unsent input. The sequence below records this checkpoint's historical boundary; runtime qualification remains pending.

1. Handle prefixes consisting only of observations when subsequent input becomes uncertain, retain-only scopes, and explicit supersession of earlier work. Preserve original evidence and purposes without inventing input receipts.
2. Review checkpoint recovery after process/document loss and failures during native retirement or durable publication. Current native-proof ownership cannot be reconstructed from current matching values. Conservative interruption remains a limitation where original authority is unavailable.
3. Qualify semantic pending-field mapping, dependent controls, control equivalence, account/login transitions, preservation timing and whole-task result verification. This bounded form checkpoint does not finish the broader [repair TODO](../../../TODO.md).
4. After explicit execution permission, compile and run the prepared regressions, then qualify lightweight models and the retained real travel/concert/movie scenarios. The extra preparation/planning stages have not been measured. Alternative models and the authorized RTX 3080 desktop remain options after measured model failures; the 8 GB Mac target and deferred performance work remain unchanged.
