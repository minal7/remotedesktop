# Review offer association before using result fields

Parent: `1c6c322`. This checkpoint adds semantic field review to the default browser research composition. It is source integration with syntax and inventory checks only. The app still cannot return a completed research answer, and the changed model contracts have not been qualified.

## First-principles findings

An observation answers what a page contains. Interpretation answers what that content means and which offer it describes. Mechanical comparison answers whether an interpreted value meets one constraint. Task completion requires all requested results and constraints, supported by current evidence. These are separate obligations.

The existing reader could group a title and price under the same ancestor. The assessment could then correctly calculate that `USD 40` is below `USD 50`. Neither operation establishes that the price belongs to the requested concert, applies to the selected ticket, includes required fees, or remains available. A surrounding “From,” a second ticket option or a page-wide date filter can change the meaning without changing that number.

The previous assessment deliberately called this a quoted-value comparison, but it had no explicit place to retain semantic disagreement with the initial grouping. A later planner had to rediscover that disagreement from page text. That is a correctness gap even before choosing a different model.

| Failure | Source change in this checkpoint | Remaining obligation |
| --- | --- | --- |
| A shared container combines several offers | Review labels the association single, mixed or unknown | Qualify semantic accuracy and identify distinct offers across pages |
| A field belongs to global context | Every field retains offer/page/unknown scope | Resolve selected options, filters and conditional applicability |
| A number is qualified elsewhere | Price interpretation distinguishes exact/qualified/unknown; qualifier references may use surrounding text | Verify pricing meaning, basis, fees, inventory and options |
| A review omits an inconvenient field | Decoder requires the exact candidate and field counts in the original order | A correctly shaped response can still be semantically wrong |
| A cached review is attached to another reading | Full goal, private page input and original selections are compared exactly | Native freshness still must be checked after model work |
| A malformed review abandons research | Typed review failures retain a resumable intervention under the original driver | Broader transport/runtime failure handling and durable recovery remain open |

## Implemented source path

The default loader composes the existing result reader with a review planner. Both use the existing verified native-text runtime owner; no independent model worker is allocated. The owner performs its native preparation and page revalidation after both stages. Review cannot navigate, type, create a destination or bypass the existing source, authentication, ownership and journal checks.

The review input retains the complete original request, fixed clock/time zone, all accepted clarification answers, the exact original reading projection and every selected candidate/field/link reference. Hidden native page contents and the exact goal remain in its private equality binding. The model sees no native destination, session identifier, candidate authority or current control value. Page contents and initial groupings remain untrusted data.

The response has only candidate associations and per-field scope, price interpretation and observed qualifier text references. There is no rewritten fact, normalized amount/date, URL, confidence score, action or completion field. Strict decoding rejects extra/duplicate keys, missing/extra candidates or fields, invented/non-text references, duplicate qualifier IDs and inconsistent combinations. A price field cannot use `notPrice`; other fields must. `exact` requires offer scope and a single-offer interpretation. A single-offer title must be scoped to that offer. A qualified price requires a qualifier reference, including the field's own complete record when appropriate.

Known text/structure omissions prevent positive offer assertions. Omitted controls remain disclosed separately: the flag does not prove that selected options or filters are known. The prompt requires unresolved dependent fields to remain unknown. This is still a model interpretation; the host cannot verify that instruction through JSON shape alone.

Each field permits at most eight qualifier references, with at most 128 references across the response. The original reader still limits candidates to eight and fields to sixteen per candidate. Review preserves all fields rather than selecting a convenient subset. Exact input counting admits at most 3,008 tokens under the existing 4,096 context / 1,024 output / 64 framing reserve. The 30-second authenticated loopback request keeps deterministic sampling settings and disables prompt caching. An oversized complete input is rejected; the goal or page is not silently shortened. Output length or envelope failure cannot publish a partial review.

Empty candidate sets skip review inference and model activation. An already attached review may be reused only for the exact input. A changed review changes native candidate and link-selection identity, including changes to another candidate in the same reading. Native review reuse also checks the retained review, current complete goal and fresh page evidence. Cancellation during either stage prevents publication; the existing owner keeps its operation slot until actual unwind.

The assessment now exposes mixed-offer, unresolved-association, page-context and qualified-price concerns instead of presenting a numeric match alone. These labels are explicitly review-derived. A positive review permits only the existing quoted-literal comparison. It does not create an exact scalar observation, certify availability or finish any requirement outside that comparison. Count requirements still need a result set, and source eligibility remains a separate native fact.

Link input version 4 carries the complete field review beside requirement assessment version 2. Quote entries include their original field indices. Link instructions describe the review's limits and use its unresolved concerns to seek further evidence. Invalid, stale or over-budget review proposals return a retained intervention; cancellation still propagates. The new recovery branch does not convert failure into success or admit desktop fallback.

## Prepared regression coverage

Twelve methods in `ComputerUseBrowserResultReviewTests` cover:

1. Complete scoped answers, original request/clock, surrounding qualifiers and private native authority.
2. Closed response coverage, inconsistent labels, missing/extra fields, invented facts and references.
3. Text/structure/embedded/projection omissions and qualifier limits.
4. Exact goal, root, snapshot contents, hidden destination and original field-role binding.
5. Exact request admission, sampling/transport configuration and empty-reading short circuit.
6. Malformed model envelopes and cancellation after token counting or completion.
7. Composite reader/reviewer binding, stale replies and exact-review reuse.
8. Native driver assessment/link composition across exact, qualified, page-wide, unknown and mixed interpretations, without a completed answer.
9. Changed-review candidate/link identity, mismatched review reuse, login control loss and superseded native evidence.
10. Pause during a reviewer that ignores cancellation, joined unwind and Resume without repeating the search.
11. Invalid-review recovery preserving the native owner without desktop fallback or repeated initial search.
12. Native navigation during review preventing publication or use of the earlier reading.

The existing link-context method now expects the new nullable review field. These are controlled proposal and loopback fixtures prepared for later execution; they do not measure model accuracy or real-site behavior.

## Checks actually performed

Ten changed Swift files passed syntax-only parsing after correcting two missing closing brackets in the new test source. Xcode project syntax and registration, whitespace and both source inventories passed. The three new Swift files each have their four project entries. The [focused inventory](browser-result-review-inventory.json) selects 255 methods; the default selects 938, twelve more than the parent. These counts identify source methods, not passing assertions.

**No typechecking, builds, tests/assertions, model inference, app launches, browser/computer-use activity or live E2E ran.** Installed app, model/runtime assets and held-out qualification sets remain untouched. No build intermediates or disposable scratch artifacts were created. No new SSH attempt or remote training was made.

## Repair sequence still required

1. **Qualify semantic interpretation independently.** A second call to the same model can repeat the same mistake. JSON validation proves reference integrity and coverage, not meaning. Freeze annotated development examples containing mixed offers, variants, global filters, qualifiers, contradictory prices and malicious page instructions. Measure false positive association and price-exactness errors separately from conservative declines. Preserve separate held-out qualification data.
2. **Add complete requirement-to-evidence bindings.** Every requested route, location, date/time, category, availability condition, price basis/fees, preference and prohibition needs applicable evidence or an explicit unresolved status. The present review does not prove field roles are correct or that an omitted field was unnecessary. Keep literal arithmetic separate from semantic applicability.
3. **Represent distinct offers and chosen options.** Preserve issuer/seller, event/trip/showing identity, relevant ticket/fare/seat/party choices and the observation context. Do not deduplicate by title/price alone or interpret selected-card counts as available inventory. Resolve contradictory or changed observations explicitly.
4. **Implement complete result sets and answers.** Preserve cross-page evidence, requested counts, ordering and comparisons, and verified useful public links. Do not export authentication callbacks or private destinations as citations. Partial search results must not become a claim that no other options exist.
5. **Complete general browsing actions.** Site entry, search forms, location/date controls, selection widgets, pagination and detail pages need observed targets, explicit prerequisites and durable action state. Review labels cannot substitute for these capabilities. The present page-wide omission rule can withhold positive labels on large pages even when a particular card is fully visible; develop explicit evidence coverage for the relevant card and inherited context before relaxing it. Bound no-progress behavior and distinguish missing evidence from an unsatisfied condition.
6. **Finish login continuation.** Qualify current host/phone handoff controls, provider popups, blocked account redirects, explicit handback and remaining-goal reconciliation. No AI effect should occur during user control. An attempted action still needs reconciliation before any retry; a logged-in page does not itself prove task success.
7. **Qualify the full default composition when authorized.** Typecheck/build, then execute bounded parser/native/runtime checks before any later real travel/concert/movie scenarios. Include cancellation, incomplete contexts, model failures and post-login continuation. The new review adds one sequential inference per nonempty unreviewed reading and adds context to link selection; latency, token-budget fit and semantic benefit remain unmeasured.
8. **Choose or adapt models from evidence.** The user has authorized other models and the designated RTX 3080 desktop. SSH access remains unresolved after the earlier timeout. Verify remote access/hardware before remote work, distinguish model mistakes from routing/persistence/observation defects, and compare baseline candidates under the same complete-goal and action contracts. Distill or prune only against demonstrated use-case failures, retaining independent held-out evaluation. Later qualify total application memory and thermal behavior against the 8 GB Mac target; shared worker ownership alone does not establish lightweight operation.

Dependencies: [result assessment](BROWSER_RESULT_ASSESSMENT_REVIEW.md), [price clarification](BROWSER_PRICE_CLARIFICATION_REVIEW.md), [result grouping](BROWSER_RESULT_CANDIDATES_REVIEW.md), [default composition/source requirements](BROWSER_SOURCE_REQUIREMENTS_REVIEW.md), [research driver](BROWSER_RESEARCH_DRIVER_REVIEW.md) and [login handback](BROWSER_LOGIN_HANDBACK_REVIEW.md).
