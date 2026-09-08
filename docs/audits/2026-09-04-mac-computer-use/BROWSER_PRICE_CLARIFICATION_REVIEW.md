# Bind scoped price answers without replacing the original constraint

Parent: `5231858`. This checkpoint connects supported currency, price-basis and fee clarification answers to the original price predicates and native candidate assessment. It remains source-only and does not complete semantic offer verification or research answers.

## First-principles finding

Preserving an answer in the transcript does not make it affect execution. Previously, `under $50` remained a dollar-symbol predicate after the user explicitly answered “USD.” “Per ticket” and “including fees” were retained as separate uncompiled fragments. The app could ask for information but still compare against the old incomplete price meaning.

Applying an answer globally is also wrong. Two identical amounts may describe different budgets. A clarification must retain its exact task and source scope, change only the relevant parameter and preserve the original amount and comparison. A later conflict must not reset an earlier unresolved parameter to a convenient default.

## Source implementation

Scalar compilation first retains its complete existing requirement ledger, then processes the bounded, accepted clarification turns in order. Only currency, price-basis and fee topics participate. A whole explicit parameter answer is recognized from the user turn and sealed question context, rather than from model value hints. Supported forms include the existing ISO currencies and specified common names, total/per-person/per-ticket wording, explicit fee inclusion/exclusion, yes/no for the corresponding fee question, and limited ordinary polite phrasing. Original answer bytes remain in the goal; normalization is only for interpretation.

Target selection uses the original question's source turn, byte offset and exact source text. A current parsed price clause must lie inside that scope at the same occurrence. The existing price-clause normalization tolerates source partition changes around whitespace, “and” and sentence punctuation; comparator, value and qualifier bytes remain exact. One price inside an earlier broad outcome scope can resolve. Multiple prices inside one broad scope remain ambiguous. Explicit separate scopes can address several price clauses, with atomic application across all of them.

A follow-up can refer to an earlier successfully bound whole parameter answer, including a source span that expresses that same known parameter. Its target remains the original price clause. Arbitrary fragments, unsuccessful earlier answers and matching values elsewhere do not supply this association. This is a limited typed reference chain, not general semantic correction handling.

The original amount and comparator never change. A supported explicit currency can disambiguate its compatible symbol; an existing different ISO currency cannot be overwritten. Price basis and fees can fill unspecified values or confirm the same value. Conflicting currencies, bases or fee interpretations remain unresolved. Multi-clause updates apply atomically. Earlier unresolved state cannot be replaced with base defaults while applying a later parameter. If a target becomes unresolved, earlier answer bindings to that target are invalidated as well.

Each accepted parameter answer keeps a `clarification` ledger entry bound to the current goal revision and exact target requirement IDs. Source-covered fragments of the same recognized whole answer retain the same binding; no extra answer clause is discarded. Compound, negative, uncertain or amount-changing answers are not reduced to a copied hint such as “USD.” They remain unresolved with their target constraints. Complex intent changes and recovery from such answers require further whole-goal clarification work.

In otherwise research-classified proposals, a whole literal answer's host-known meaning takes precedence over a mistaken model source label. The source compiler therefore does not turn a currency answer into a website restriction. This does not override an unresolved overall model disposition or infer parameter meaning from unscoped text. The result assessment reports `clarificationApplied` separately from page evidence, while the original price row uses the updated predicate. This status proves no offer fact or task completion.

Goal-planner instructions now prefer the original price clause for parameter questions. Link-planner instructions explain the new assessment status. The existing owner, question/session transport, source configuration and native reading boundaries carry the updates; no new model stage, worker or effect path was introduced.

## Prepared coverage

Eight new scalar/clarification methods and one added native-assessment method cover:

- Three successive currency, basis and fee answers preserving the original root, clock, amount, comparator and exact answer ledger, including replay rejection.
- Identical price occurrences, unique versus ambiguous broad scopes and atomic multi-price conflicts.
- Explicit currency/basis/fee conflicts and preservation of unresolved earlier state.
- Compound, negative and uncertain answers, including model hints or source fragments that attempt to retain only the convenient “USD” part.
- Follow-up through known earlier answer parameters despite source partitioning.
- UTF-8 source offsets, boundary conjunction/whitespace changes and invalidation of earlier bindings after a later conflict.
- A sealed literal parameter taking precedence over an incorrect source field label, with unscoped source text still unresolved.
- The actual retained owner and native candidate pipeline applying all three parameters, preserving the original task, rejecting a spurious source question and avoiding another initial search.

These are controlled proposal fixtures, not actual-model qualification. The native case is prepared to use the owned-browser loopback fixture when execution is authorized.

## Checks actually performed

Seven changed Swift files passed syntax-only parsing. Project syntax, Xcode registration, whitespace and both source inventories passed. The new test file has its four target entries. The [focused inventory](browser-price-clarification-inventory.json) selects 243 methods and the default selects 926, nine more than the parent. These are source identifiers, not passing assertions.

**No typechecking, builds, tests/assertions, model inference, app launches, browser/computer-use activity or live E2E ran.** Installed app, runtime/model assets, held-out sets and prior qualification evidence were unchanged. No disposable build artifacts were created.

## Remaining work

1. Complete general clarification and correction semantics, including compound answers, unresolved earlier answers, narrower/changed source scopes, separate fee clauses, broader currencies/wording and other date/location/quantity parameters. The present binder deliberately leaves unsupported forms unresolved; it does not make every possible follow-up recoverable.
2. Bind full semantic offer association, qualifiers, routes/times, category, availability and prohibitions. Literal price matching and acknowledged user parameters do not prove those facts.
3. Assemble distinct qualifying result sets with requested counts/ranking, cross-page evidence and useful source links, then produce verified answers. Complete general site/form/date/location/choice interactions and durable recovery.
4. Complete blocked account-redirect takeover and post-login reconciliation through actual current host/phone controls. Attempted effects still cannot simply be replayed.
5. When authorized, typecheck/build and run bounded native and actual-model checks, including the changed prompt and compiler contracts, before the deferred real travel/concert/movie scenarios. Alternative models and RTX 3080 adaptation remain available; access details are still pending after the earlier SSH timeout. Performance and 8 GB/thermal qualification remain later work.

Dependencies: [result assessment](BROWSER_RESULT_ASSESSMENT_REVIEW.md), [source requirements/default composition](BROWSER_SOURCE_REQUIREMENTS_REVIEW.md), [goal clarification](BROWSER_GOAL_CLARIFICATION_REVIEW.md) and [research driver](BROWSER_RESEARCH_DRIVER_REVIEW.md).
