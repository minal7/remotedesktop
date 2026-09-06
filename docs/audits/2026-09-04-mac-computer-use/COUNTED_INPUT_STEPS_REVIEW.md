# Counted input steps before later actions

Parent source: `68d1d01`. Status: source implementation and prepared regressions only. No type checking, build, test execution, inference, app launch, computer use or real-website task ran. The user's execution pause and deferred performance priority remain in force.

## First-principles failure

An occurrence count is part of the requested action. `Type "Paris" twice, then press Return` requires two inputs before Return. One history entry cannot discharge the counted clause or authorize its successor.

The previous ordered resolver had a repetition check only when evaluating terminal prerequisites. Its action-admission path could treat a counted TYPE as one input and advance to the following clause, even though the terminal path later refused to call the task complete. The Return-key parser also did not recognize counted Return clauses. The separate explicit-clause repair did not solve either problem.

## Source change

A single preprocessing step now expands supported trailing counts before the shared ordered resolver constructs its action list. Action admission, pointer prerequisites, terminal prerequisites and terminal continuation therefore consume the same sequence of input occurrences.

Supported forms are an exact quoted literal input or an unambiguous `Press Return` / `Press Enter` key clause followed by `twice`, `thrice`, a numeric count or a spelled-out count with `time`/`times`. Optional `exactly` before the count and `please` afterward are accepted. Counts range from one through eight per clause, with at most 32 expanded counted-input occurrences per request. The executor's own action-step budget still applies independently.

Each expanded occurrence retains the exact literal bytes and the ordinary input-clause meaning. The original full request remains the retained task identity. The model does not supply a count, rewrite the literal or create host-history entries. A long literal can continue through its existing host-owned reference; the count changes occurrences, not payload identity.

The source deliberately validates the actual text following the frequency, even though the frequency matcher masks quotations. Otherwise `Type "Paris" twice "London"` could discard a second quoted object. Dangling target introducers also reject expansion: a field named `Twice` must not become two inputs into an unspecified field.

Existing `once` instructions keep their original parsing, including following field scope or submission purpose. Unsupported count placement, multiple frequency expressions, unbounded repetitions, signed/fractional counts, unknown counts and out-of-range counts do not become a one-shot prefix. Signed/fractional frequency rejection occurs before sentence splitting can lose the fractional suffix. Ordinary factual questions without an input command keep their existing routing behavior.

Unexpanded repetition remains a barrier for every shared-resolver consumer, including admission of a later effect. This includes counted pointer actions and Return-named controls; the input compiler cannot reinterpret those controls as keys. Separate explicit pointer clauses retain their existing behavior. Supported input counts have already been expanded by the time this barrier is checked.

The preceding [ordered repetition repair](ORDERED_INPUT_REPETITIONS_REVIEW.md) still governs replay: each recorded raw effect consumes one occurrence, a mismatched/exhausted prefix rejects more input, and uncertainty stops before another attempt. This change does not create durable target-bound receipts or turn input history into evidence of search results.

## Prepared regression coverage

Three methods are added:

1. Resolver checks for TYPE and Return counts, word/numeric spellings, `twice`/`thrice`, the upper per-clause bound and `1 time`. Every partial prefix must still bind the counted input and reject the later action. Only the full counted prefix admits the successor, and only all requested occurrences can satisfy terminal prerequisites.
2. Unsupported-count rejection before input and before the successor, including zero/out-of-range/unknown/signed/fractional counts, unbounded or unsupported placement, duplicate modifiers, target-name ambiguity and extra quoted data. Count-like words inside the actual quoted literal remain data. Existing `once` scope and ordinary factual arithmetic wording are preserved. Counted single/double/right clicks cannot be consumed as one pointer occurrence to authorize later typing.
3. Production executor checks with stub routing and an intercepted input sink: early Return after one of two TYPEs, an extra third TYPE, early typing after one of two Returns, invalid fractional/zero frequencies and a counted-pointer prerequisite all reject at the host admission boundary.

Three existing methods are extended:

- Direct semantic proposals and recovery from premature COMPLETE proposals now each include counted literal input, three Returns and repeated long literal references. They must produce the declared input sequence, then stop at the fixture's action bound without claiming a successful search.
- Retained-execution coverage now includes counted wording in both cancellation-before-second-proposal and uncertain-input branches. Confirmed prior occurrences survive Resume; uncertain delivery cannot authorize a retry or another runtime activation.

These effect sinks record requested calls. They do not exercise physical keyboard delivery, application mutation, WebKit submission or a local model's natural-language decisions.

## Verification and remaining work

The default manifest selects **604** source methods. The [focused manifest](counted-input-steps-inventory.json) selects **70**, including the prior ordering, one-shot replay, editable focus, terminal, approval, late-planner and lifecycle cases. Exact source inventories, syntax parsing of the three changed Swift files and `git diff --check` pass. Syntax parsing does not resolve symbols or prove concurrency/protocol conformance. No assertions executed; historical manifests remain unchanged.

Remaining requirements:

1. Compile and run the prepared regressions when execution is authorized. Qualify actual editing, Return delivery, interruption and result observation through production host/browser composition.
2. Extend repetition grammar through an explicit reviewed contract where needed: count placement before field scope, `again`, block repetition, conditional/unbounded repetition, pointer/shortcut/scroll counts and counts outside current bounds. No general repeat-language claim is established.
3. Bind every visual input to its intended target and document, durable step identity, attempted/verified/uncertain receipt and independent outcome predicates. A count and exact literal are not sufficient target authority by themselves.
4. Complete full browsing goals, search/date/location control, post-login remaining-goal reconciliation and verified result/source-link extraction. Repeated Return proves neither repeated searches nor correct travel/concert/movie results.
5. Review the bounded model-facing history representation for longer workflows while keeping full host effect history as admission evidence. Runtime, 8 GB and fan-load qualification remain open and deferred.
