# Retain and recall research evidence across pages

Parent: `083eb76`. This checkpoint connects a bounded historical reading archive and model-requested recall to the retained research driver. It remains source integration; current runtime behavior and model accuracy are unqualified.

## First-principles finding

Research requires comparing observations collected at different times and on different pages. A navigation receipt records that a load occurred; it cannot substitute for the information on that page. Before this change, the owner retained only `latestCandidates`. Navigation, Pause and clarification invalidated that cache. The driver's history preserved operation IDs and goal revisions, but no earlier candidate evidence was available to its link planner.

Keeping the old actionable cache would be wrong too. An old page's element IDs, link destinations, account state and availability cannot become current authority merely because the task remembers them. Historical observations need separate retention and explicit recall, with current actions still bound to the live page.

## Source implementation

The owner now records each candidate reading after result planning/review, native preparation and current-control/goal checks. The archive retains the complete original bounded page projection, candidate fields and surrounding records, original semantic review, original requirement assessment, source-status provenance and private native/goal binding. It is task-local memory, not a disk journal or fresh availability proof.

The default archive permits 64 readings. A new native observation remains a separate entry even if its visible text resembles an older page. Revalidation of the exact same immutable reading is idempotent. Capacity is checked before another model reading; a full archive retains earlier entries and returns an intervention instead of silently evicting them. A bounded configurable lower limit supports deterministic capacity coverage. These limits bound retained entry count; they are not measured total-memory or 8 GB qualification.

Entries are bound to the original root and browser context. Accepted answers may extend the exact existing clarification prefix. Foreign roots, changed answer branches, rollback to an earlier prefix after newer entries, and replacement browser contexts are rejected. Each entry keeps its original goal revision and assessment. A later answer does not rewrite an earlier price/source interpretation into a current fact. Reading identity now includes the retained goal interpretation as well as page, source-policy and review identity.

Pause preserves validated historical entries while invalidating current action targets and closing owner access to the archive. Explicit handback rechecks the existing session. Retirement clears the owner's archive and blocks later access; this does not claim to erase copies already supplied to an in-flight model request. A reading cancelled before native validation cannot append. The owner continues to hold its operation slot through actual selector/model unwind.

Both normal selection and proven-unsent pending-navigation replanning now receive an immutable archive snapshot. Link input version 5 contains a compact catalogue of every stored ordinal, whether its goal matches, whether it is the current reading, candidate count and review presence. This catalogue is an index, not semantic evidence or a distinct-offer count. A missing archive remains explicit rather than implying that no history exists.

The version-2 link response contract has two closed alternatives: the existing current candidate/link selection, or a single `reading` ordinal from the offered recall set. Strict decoding rejects hybrid responses, extra or duplicate keys, non-integral indices, unoffered/current/already-recalled entries and stale input bindings. A recall proposal cannot be consumed as a link choice.

The model adapter handles recall under the existing owner operation. It adds the requested historical observation to the next input and asks the same planner again. Previously recalled observations remain in that selection's context. Up to eight distinct earlier readings may be recalled before a final link/no-link response, giving at most nine planner decisions per selection. Recall also works when the current page offers no candidate links. It performs no browser navigation, DOM operation or input effect and allocates no new worker.

Historical reference fields are namespaced by reading, such as `r0/t1`, `r0/g1` and `r0/l1`. This includes container relationships, selected fields, link text references, unclassified text, qualifier references and assessment quotes. Actual observed prose is unchanged. Historical link IDs cannot alias current-page link IDs or pass the current action schema. Exact native URLs, session identity and candidate authority remain private.

Each decision still counts the exact complete request under the existing context/output limits. Recalled data, the catalogue, navigation history and current goal/page are not silently shortened when they exceed the limit. Typed recall, capacity and link-planning failures retain a resumable research owner; they do not authorize completion, desktop fallback or replay of the initial search. Native current-page validation still follows the entire selection operation before a link can be used.

## Prepared coverage and source correction

Nine new native/proposal methods cover:

1. Two-page research retaining both readings, recalling one without another load, and revalidating the current reading without duplicating history.
2. Historical reference namespacing across hierarchy, fields and qualifiers, preservation of observed prose, and rejection of historical links as current actions.
3. Exact clarification-prefix retention, original clock, old-goal annotations, foreign roots and foreign browser contexts.
4. Closed recall responses, repeated/current/unlisted indices, stale replies and changed archive bindings.
5. Recall without current links, identical counted/completed request bodies, preserved recalled context and over-budget refusal before the next completion.
6. Pause during recalled-evidence planning, joined cancellation, explicit handback, preserved history and no repeated initial search.
7. Cancellation or retirement before a reading is validated, preventing late archive publication.
8. Capacity without eviction and idempotent recording of the same observation.
9. Eight distinct recalls retaining their entire ordered selection context and terminating the recall allowance.

The earlier result-review fixture used `x1`, `x2`, etc. for extra text records. Source inspection showed that the page validator accepts only numeric `t`-prefixed text IDs. The fixture and its qualifier-limit references now use valid, non-overlapping `t5` and later IDs so those future checks can reach the intended omission/reference cases. The prior syntax pass could not detect this fixture defect, and the earlier source-inventory count never established that its assertions passed.

These are controlled model responses and native loopback fixtures prepared for later execution. They are not real-model or real-website evidence.

## Checks actually performed

Ten changed Swift files passed syntax-only parsing. Xcode registration/project syntax, whitespace and both source inventories passed. The two new Swift files each have four project entries. The [focused inventory](browser-research-evidence-inventory.json) selects 264 methods; the default selects 947, nine more than the parent. These are source identifiers, not passing tests.

**No typechecking, builds, tests/assertions, model inference, app launches, browser/computer-use activity or live E2E ran.** Installed app, model/runtime assets and held-out qualification sets remain untouched. No disposable build artifacts, new SSH attempts or remote training runs were created.

## Remaining repair sequence

1. Associate historical observations with distinct offers and selected variants without confusing repeated readings with distinct inventory. Preserve disagreements, changing prices, route/date/time context, fees and availability. Reassess applicable historical facts against every current constraint rather than trusting old assessment status.
2. Build result-set comparison, requested count/ranking and verified answer assembly. Historical recall is evidence access, not fulfillment. Public source links still require native destination provenance and removal of private authentication/session material through a separately qualified public-link capability.
3. Complete durable whole-task recovery. This archive currently survives retained-owner navigation, clarification and login handback; process restart and loss of the owned browser still require durable state and reconciliation. Do not serialize actionable native references as reusable capabilities.
4. Qualify useful retrieval and context fit. The catalogue supplies order and counts, not searchable semantic summaries. Large histories or several full recalled projections may exceed the current small-model budget. Add trustworthy relevance/retrieval and explicit coverage before changing retention or projection rules. Preserve the original request and make any unavailable evidence explicit.
5. Complete general site/form/date/location/choice actions, pagination, blocked account-redirect takeover and remaining-goal continuation. A remembered earlier page does not authorize revisiting its URL or replaying an attempted action. Qualify current host/phone Pause, Resume, Stop and provider popup behavior.
6. When authorized, typecheck/build and execute bounded native/runtime/model checks against this exact composition and union schema. Measure recall usefulness, repetition, stale-ID confusion, context failures and cancellation. Only later run the deferred real travel/concert/movie scenarios with explicit permission.
7. Compare or adapt models when evidence identifies model failures. The RTX 3080 desktop remains authorized but SSH access is unresolved after the earlier timeout. Keep model selection/adaptation separate from application-state failures. Later qualify memory, latency and thermal behavior against the 8 GB Mac requirement; no such performance claim follows from this source change.

Dependencies: [semantic field review](BROWSER_RESULT_REVIEW.md), [result assessment](BROWSER_RESULT_ASSESSMENT_REVIEW.md), [research driver](BROWSER_RESEARCH_DRIVER_REVIEW.md), [login handback](BROWSER_LOGIN_HANDBACK_REVIEW.md) and [price clarification](BROWSER_PRICE_CLARIFICATION_REVIEW.md).
