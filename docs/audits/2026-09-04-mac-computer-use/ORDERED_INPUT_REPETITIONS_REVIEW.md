# Ordered input repetitions and replay

Parent source: `55cb135`. Status: source repair and prepared regression updates only. No build, type checking, test execution, model inference, app launch, computer use or website task ran. Live scenarios and performance work remain deferred.

## First-principles problem

A payload identifies the data being entered; it does not identify an occurrence of a requested action. Likewise, Return identifies a key, not a unique search submission. The same city may be entered in two fields, and two searches may each require Return.

The visual executor already resolves the next explicit input clause from the full trusted request and ordered raw host history. Nevertheless, `semanticEffectIsAuthorized` then rejected every TYPE payload already present anywhere in that history, and every Return after the first Return. That second check made valid subsequent clauses impossible even when the ordered resolver had proved their exact predecessors.

Two existing regressions encoded this failure as expected behavior: they required one input for `Type "repeat", then type "repeat"`, and one Return for `Press Return, then press Return`. The native form contract already assigns distinct edit occurrences; the visual path needs to preserve this distinction too.

## Source repair and scope

The executor now remembers whether its input authority came from the next ordered clause. That proof permits the proposed input despite an identical earlier payload or key. The input must still satisfy the current clause's exact payload/Return authority, and the unchanged focus, context, approval, cancellation and effect-boundary checks remain mandatory. Input outside a bound ordered sequence retains the prior one-shot restriction.

The shared resolver consumes each complete raw host-history occurrence against one requested clause in order. A second identical TYPE cannot skip an intervening Return, and a second Return cannot skip the intervening TYPE. Once the sequence is consumed, another input proposal is rejected. Exact text still compares UTF-8 bytes, including the existing full-payload digest for long history entries. A bare, model-compacted TYPE hint cannot prove a typed predecessor.

The input resolver additionally rejects unknown/terminal history entries before the shared resolver's `compactMap` can discard them. The existing transient-overlay WAIT diagnostic remains an explicitly accepted no-effect observation. This API consumes complete host history; router summaries are not its evidence source.

The earlier [input-order review](VISUAL_INPUT_ORDER_REVIEW.md) recommended retaining all global repeat guards pending general step contracts. This repair narrows that restriction for the already compiled, explicit, ordered input subset. The relevant source boundaries are:

- The executor retains the exact current request and rejects same-ID changes in its bytes.
- Raw history is local executor state, separate from the model-facing compactor. Only the completed host effect path appends input entries.
- One executor call owns the mutable loop. An unresolved effect sets `effectNeedsReconciliation` before dispatch; it cannot resume another attempt while that flag remains set.
- Checkpoint retention on every loop exit preserves completed occurrences across cancellation and Resume. Cancellation after a confirmed input cannot erase its history entry.
- Host-approved continuations retain their own one-use authority; this repair does not bypass approval or convert a proposed effect into a receipt.

These boundaries support ordered continuation within the retained executor. They are not durable, target-bound step receipts and do not establish crash/restart recovery, general browser search or result correctness. The incomplete requirements remain on the TODO list.

## Prepared coverage

Two existing executor methods are renamed and revised to expect all explicit occurrences. They exercise direct semantic proposals and recovery from premature COMPLETE proposals, using the production executor policy with stub routing and an intercepted input sink:

1. Differently cased literals around Return preserve their existing ordering.
2. Two identical literal clauses perform two inputs.
3. Two explicit Return clauses perform two key actions.
4. Two identical TYPE/Return pairs perform all four actions in order.

These fixtures intentionally end at their action-step bound; they do not declare a successful search or task completion.

Four methods are added:

- Resolver occurrence accounting through both TYPE/Return pairs, rejection of reordered/exhausted/extra input, no-effect waits, case mismatch and incomplete TYPE history.
- Rejection of unknown, terminal and unreviewed diagnostic history before/between input occurrences.
- Production executor rejection of a third TYPE/Return when only two were requested, and rejection of an identical input proposed before an intervening prerequisite.
- Same-task continuation after cancellation before the second proposal: the first input remains recorded and only the second occurrence is performed. A separate branch throws inside the input boundary; the retained uncertainty requests reconciliation before any further runtime activation or effect.

The existing one-shot replay regression remains selected, as do target/editable-focus, exact-literal, terminal-continuation, late-planner, approval, ownership and same-request identity cases. No prepared assertion has executed.

## Validation and remaining requirements

The default inventory now selects **601** methods, and the [focused inventory](ordered-input-repetitions-inventory.json) selects **67**. Exact source inventories, four-file `swiftc -frontend -parse` and `git diff --check` pass. Syntax parsing does not resolve types, check concurrency, compile the application or run XCTest. Historical manifests are retained unchanged; their renamed methods describe their original source revisions.

Continue with:

1. Compile and execute these regressions only after the user authorizes execution. The effect sink records calls; it does not demonstrate actual key delivery, page submission, IME behavior or browser result updates.
2. Add durable task/step IDs, target/document generations, effect identities and attempted/verified/uncertain records across all visual effects. An input history entry does not independently identify a page, field or successful search result.
3. Compile full browsing goals and their remaining obligations after login. `Find flights`, date/location constraints, comparisons, result extraction and source links cannot be replaced by a TYPE/Return sequence.
4. Support explicit count-based wording such as `twice` with a reviewed expanded step contract. This patch supports separate explicit clauses; it does not claim the general repeat grammar. Unsupported operations stay barriers.
5. Review model-facing history compression for longer repeated workflows. The current schema-four compactor still preserves selected marker types rather than a complete step record; host admission remains bound to its separate raw history. The prepared two-search input sequence does not qualify longer planning behavior.
6. Continue result-specific completion checks. Two authorized Return key events do not prove two successful searches, correct results or fulfillment of the user's whole task.
7. Preserve uncertainty across manual takeover and new page targets instead of blindly rebuilding the whole original request. Real travel/concert/movie and account tests remain deferred until development readiness and explicit permission.
