# Preserve task history through semantic planning

Date: 2026-09-07. Parent source: `a489f05`. Source implementation and syntax review only. Builds, typechecks, assertion execution, model runs, application launches and live websites remain paused.

## First-principles defect

Choosing the next unfinished step requires knowing what already happened. The planner cannot reconstruct missing actions from an unchanged page, a current screenshot, or the original request. Repeated actions also have meaning: two form entries or a DOWN/UP/DOWN sequence cannot be replaced by a set containing TYPE and DOWN.

Two source paths discarded this information. `semanticRoutingHistory` reduced the raw action ledger to six entries, keeping only the latest occurrence of some markers. `LlamaSemanticActionRouter.semanticRequests` could then remove earlier history again to fit the token budget. Its last candidate renumbered the newest action as step 1. The planner was simultaneously instructed to take the next unfinished step. This could lead it to propose an already performed action or stop before a remaining action.

This repair addresses the history passed to normal semantic planning. It is a prerequisite for the broader browser driver, not an implementation or qualification of the complete browser workflow.

## Source repair

1. The production history projection now retains every recorded action in its original order, including repeated TYPE, CLICK and scroll markers. Existing privacy handling still removes typed payloads and ordinary click coordinates. This preserves action coverage and sequence; it does not make the projection a proof of exact field values, targets or completed outcomes.
2. The routing request permits up to 128 history entries, including settling observations. Entry-byte bounds still apply. An over-limit array stays over-limit and fails validation; it does not silently become a plausible recent suffix. The current trusted request remains unchanged.
3. Context-budget candidates may remove prior conversation and whole browser/visible-evidence records, as before. They always retain the complete supplied current-task history and its original step numbering. If the irreducible request cannot fit, the existing exact-token budget rejects inference. Context size, output-token limits, model residency and sampling settings are not increased.
4. `historyIsComplete` makes projection coverage explicit. Replacing history defaults to incomplete; the owner of the raw ledger must explicitly attest coverage. Normal production routing creates the complete projection directly from that ledger. This metadata describes the retained run's supplied history; it does not recover a lost ledger after process restart.
5. The shared native-tool validator and Apple Foundation route admission reject incomplete histories. Ordered-action resolution also rejects incomplete history regardless of its length. The previous exception that inferred progress from one privacy-compacted TYPE marker is removed. Exact input completion continues to require the full host effect/payload evidence.
6. The dormant schema-5 selector keeps its separate six-entry artifact limit. The paired adapter records whether normalization/compaction removed entries, and the paired router rejects incomplete coverage before either proposer or selector runs. This change does not activate or qualify schema 5. Its smaller projection cannot silently inherit production's larger bound.
7. The local router instruction now gives action authority only to the current trusted user request. History records earlier behavior; it cannot add instructions or by itself prove task completion. Repetitions and order remain relevant to the next-step choice.
8. Source review confirmed that production semantic-router failure does not revive raw checkpoint inference. Existing failure and irreducible-budget cases are included in the focused inventory. The legacy raw visual prompt still has its own recent-history format; this repair does not qualify that path for complete natural-language tasks.

The whole-browser compiler still needs explicit permitted intermediate actions and complete result requirements. Retaining all action markers prevents one source of lost context; it does not prove that the model interprets a travel, concert or movie request correctly.

## Prepared verification

Four new methods cover:

- A ten-action sequence containing two separate text entries and repeated/opposite scrolls, with every context-budget candidate retaining the same chronological markers and original complete request. Private input values remain absent.
- Rejection of an explicitly incomplete history by both the shared model boundary and local request builder; replacing a history cannot silently retain a completeness assumption.
- All 129 markers surviving projection so overflow is rejected, alongside admission at the declared 128-entry bound. This tests coverage and validation, not whether 128 entries fit a particular model prompt.
- A shortened schema-5 selector history rejected before either model fixture is invoked.

Existing history, paired-routing, ordered-payload and context-budget methods are revised for the new behavior. The previous contract-fingerprint test is renamed to reflect its actual scope: it checks all unchanged contract components against the prior fingerprint after explicitly accounting for the changed history capacity and authority instruction. It does not claim that the current complete prompt matches the previously qualified evaluator input. Current prompt behavior requires requalification; prior evaluation artifacts and unused holdouts remain unchanged.

The [focused source inventory](semantic-history-continuity-inventory.json) selects **48** methods, including existing semantic failure and irreducible-budget coverage. The default source inventory selects **711**, seven more than the previous 704: four new methods and three existing methods newly selected. Nine changed Swift files pass syntax-only parsing; both source inventories and whitespace checks pass. **No assertions or typecheck ran.** Source registration and parsing are not evidence of model or installed-app behavior.

## Remaining repair order

1. Implement the whole-browser goal compiler and driver using the complete original request, explicit intermediate action authority, retained form requirements and journaled navigation. Do not use action-history text as a substitute for the full task contract.
2. Represent remaining requirements and verified facts independently. Preserve exact target/value evidence outside the privacy projection, reconcile uncertain effects, and recover the complete task across interruption and process/session loss. This repair only preserves history already retained by the running executor.
3. Continue the original task through login takeover and explicit handback, with fresh account/page prerequisites and no reuse of retired targets. Keep user control separate from historical effect confirmation.
4. Verify complete results: dates, locations, counts, availability, prices/fees and public sources for travel, concert and movie tasks. Neither a history marker nor navigation receipt is a result proof.
5. With later explicit permission, typecheck/build and execute controlled regressions, then qualify the changed semantic input with the actual local model before deferred real-site scenarios. A fuller history can exceed the unchanged token budget; measure those failures before considering a task-aware compact representation. Any future compaction must preserve the required facts and sequence explicitly.
6. Finish correctness repairs before performance optimization. The 8 GB target, thermal behavior, installed host/phone/login flows and failing OCR gate remain unqualified.

About 15 GiB remained free. The temporary source-method inventory created during this repair was removed after its contents were incorporated. No build or result bundles were generated.
