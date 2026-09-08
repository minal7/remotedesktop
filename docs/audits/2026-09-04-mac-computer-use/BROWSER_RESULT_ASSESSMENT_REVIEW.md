# Account for complete research requirements against bound readings

Parent: `7c179e3`. This checkpoint adds a native-bound requirement assessment and supplies it to the existing link planner. It is an intermediate part of result verification, not a completed research-answer implementation. The installed app is unchanged.

## First-principles findings

The app already retained complete user requests and page candidates, and it could compile some scalar requirements. It had no connection between those requirements and observed values. A candidate selector therefore had no explicit record distinguishing a price mismatch from a missing price, uncompiled condition or incomplete reading.

That connection must not turn a copied number into an offer fact. `USD 40` may be copied accurately while nearby text says “from,” adds fees or describes a different option. Source grouping and field labels remain model interpretations. Literal arithmetic and offer verification require different representations.

All requirements must remain accounted for. Counting observed cards cannot establish the number of unique qualifying results or available tickets. A matching price cannot erase a route, availability condition, prohibition or source restriction. An empty candidate selection cannot establish that the website has no results.

## Source implementation

`ComputerUseBrowserScalarRequirements.Literal` represents a parsed quotation independently of `Observation`. `Condition.compareLiteral` supplies the existing arithmetic/civil-date logic for planning. The observation API retains its exactness gate: an inexact price observation remains unverifiable even when the same literal numbers compare favorably. No parsed quotation is converted to a verified observation.

`ComputerUseBrowserResultAssessment` records every interpreted requirement in original source order, including turn, exact byte span, role, field and relation. Each candidate has one status per requirement. Complete selected price, date and quantity text records are retained with their IDs; parsing normalizes whitespace only and never extracts a numeric substring from a larger record. Multiple price/date fields remain ambiguous. Missing, unparsed, incompatible and incomplete readings have distinct states.

Supported price quotation syntax includes explicit currency codes or unexpanded symbols, bounded fixed-point amounts, ordinary comma grouping, total/per-person/per-ticket basis and explicit fee wording. The parser rejects ranges, “from,” approximate or trailing qualifying prose, malformed grouping, excessive precision and oversized amounts. A symbol such as `$` remains a symbol; it does not silently become USD. Missing or conflicting basis/fees/currency cannot pass a requirement that specifies them. These checks concern the complete selected records; qualifiers in other records still need semantic association.

Date quotations require an explicit valid civil day. ISO dates and explicit English month names with a four-digit year are supported. Relative page text such as “tomorrow” cannot borrow the original task's clock: the page has its own publication and time-zone context. Missing years, ambiguous numeric formats, invalid dates and trailing qualifiers remain unparsed. Broader language/date interpretation is still required for real ticket workflows.

`quotedValueMatches` and `quotedValueConflicts` describe only literal comparison. Outcomes, places, routes, availability, ordering, prohibitions and uncompiled requirements retain unresolved statuses. Quantity requirements need a verified result set or inventory interpretation; neither a card count nor a quoted number of tickets resolves them. Answer-document origin eligibility remains separate from every numeric comparison. Truncated or omitted page/structural/embedded records prevent a positive quote comparison; omitted control values and other context still need semantic assessment.

The native candidate boundary now accepts the exact retained goal interpretation. Its assessment binds the goal revision, interpretation digest, actual document/session identity, snapshot, candidate IDs and answer-source policy. Native revalidation checks the exact retained interpretation and fresh page evidence. Pause, a new snapshot, navigation or an accepted answer cannot revive an earlier assessment as current evidence. The full original root and clock survive clarification, with both old and new user requirements represented in the new assessment.

Link-selection context is now version 3. It includes a compact requirement-status ledger alongside the full goal and existing bounded page projection. Status arrays follow the original requirement order. Model context uses indices and already exposed text IDs; native URLs, policy/goal/session hashes and candidate authority stay host-side. The additional context remains subject to the existing exact input-token gate. It is never silently truncated to fit. Dense or long requests may still exceed the model budget and need a broader context strategy.

The assessment is computed locally from the bound reading; no new planner, model activation or inference stage was added. The model can use it to seek better evidence, but cannot use a literal comparison as an answer certificate. The driver still does not return a completed research answer.

## Prepared coverage

Ten new methods use the concrete driver, source compiler, owned-browser fixture, native candidate binding and controlled goal/reading/link proposals when eventually executed. They cover:

- Complete requirement accounting, exact multi-record quotation, arithmetic/date comparisons and retained non-scalar/prohibition work.
- Price boundaries, grouping, precision, currency, basis, fees, range/“from” qualifiers and missing or ambiguous prices.
- Unclassified neighboring qualifiers remaining outside the literal comparison, without being declared verified offer facts.
- Explicit dates, invalid dates, ambiguous formats and independent page-relative date context.
- Answer-source exclusion and result/inventory count remaining independent of a price or ticket-count quote.
- Changed interpretation, lost control, fresh snapshots and navigation invalidating old assessments.
- The concrete research route supplying the assessment to link planning with the complete request and private native bindings.
- Empty candidates preserving every requirement without a “no results” conclusion.
- Accepted clarification answers preserving the original root/clock, adding all new requirements and retiring old assessment authority.
- Omitted page records preventing positive quote comparison.

The shared driver fixture can now insert controlled text inside its result card. Existing link-context expectations were updated. These fixtures do not measure actual-model semantic quality.

## Checks actually performed

Eight changed Swift files passed syntax-only parsing. Xcode registration and project syntax, whitespace and both source inventories passed. The new production and test files have their four target entries. The [focused inventory](browser-result-assessment-inventory.json) selects 234 methods and the default selects 917, ten more than the parent. These are source identifiers, not passing assertions.

**No typechecking, builds, tests/assertions, model inference, app launches, browser/computer-use activity or live E2E ran.** No model/runtime assets, held-out sets, installed application or prior qualification evidence changed. No disposable build artifacts were created.

## Remaining repair sequence

1. Bind semantic offer association and all non-scalar requirements against complete context: qualifiers, neighboring/global fields, routes, times, category, availability, source meaning and explicit prohibitions. A parsed quote and a common DOM ancestor are insufficient. Resolve scoped currency/basis/fee answers into the original scalar meaning without deleting either turn; retaining an answer alone does not compile it. Qualify the model's field/group/requirement interpretation independently of these structural checks.
2. Compile a complete result set with distinct offer identity, requested count/inventory, ranking and cross-page evidence. Persist/reconcile ordered progress without reviving stale observations. Implement truthful answer assembly with usable, appropriately projected source links and retain unresolved work when evidence is inadequate.
3. Complete general date/location/choice/form actions and site-specific entry/search. Current quote parsing covers only specified literal forms and cannot replace a general natural-language interpreter.
4. Complete blocked account-redirect takeover and post-login reconciliation through the current host/phone controls. Pending attempted navigations still cannot simply be replayed.
5. Once execution is authorized, typecheck/build and run bounded native/model qualification, including the larger link-context contract, before proposing the deferred travel/concert/movie live scenarios. Alternative-model/RTX 3080 work remains available after the prior unresolved SSH timeout; performance and 8 GB/thermal qualification remain later work.

Dependencies: [source requirements/default composition](BROWSER_SOURCE_REQUIREMENTS_REVIEW.md), [native source policy](BROWSER_SOURCE_POLICY_REVIEW.md), [result candidates](BROWSER_RESULT_CANDIDATES_REVIEW.md) and [research driver](BROWSER_RESEARCH_DRIVER_REVIEW.md).
