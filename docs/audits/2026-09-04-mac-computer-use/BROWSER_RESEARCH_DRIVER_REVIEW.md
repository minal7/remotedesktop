# Connect retained research navigation without losing the original task

Parent source: `9ebf950`. This checkpoint adds the concrete research navigation control loop and prepares regression cases. It does not establish working natural-language research in the installed app.

## First-principles findings

The existing components could interpret a goal, prepare a search, read candidate results and retain a selected navigation through interruption. The capability router could delegate to a research driver, but there was no concrete driver joining these components. Testing individual components could not establish that a complete request actually used them in the required order.

The request, ownership and effect history must remain independent of the model's next proposal. An unresolved navigation must be reconciled before selecting another action. Login changes the observed page, so an unsent target may require fresh selection; it does not authorize replaying an attempted action. A successful navigation proves a historical load, not that a relevant ticket exists or that the requested answer is complete.

Cancellation also crosses several asynchronous return boundaries. A child can finish a navigation and clear its pending stage before Pause prevents its outer result from reaching the driver. Driver-local history alone would then omit a completed visit, losing navigation order and undercounting its limit after Resume. Native facts must be retained inside the owner before returning across that boundary.

## Source implementation

`ComputerUseBrowserResearchDriver` implements the existing research execution and continuation protocols. It captures the complete current request and its original clock/time zone once. Text-only preflight can decline an unsupported request before retaining an owner or accessing a page. It checks the host action gate before and after planning, rejects a proposal for another input, and seeds the owner's first interpretation with the accepted proposal to avoid a duplicate goal-model call. An accepted clarification revision invokes the underlying goal planner again.

Preparation captures the exact owner synchronously before the outer capability admission observer can fail. Once admitted, errors cannot turn research into a no-effect decline. Continuation requires the same retained owner, current host ownership and execution ID; a changed input must be exactly one accepted answer beyond the retained revision. The original request and clock are preserved. Both driver and owner retain their execution slots until suspended work actually unwinds.

The control loop performs these operations in order:

1. Validate the retained owner and recover its confirmed navigation history before applying the task limit.
2. Resume a pending initial search. A changed starting page may be refreshed only through the existing proven-unsent path, preserving the query, provider, session and operation ID.
3. Replan a pending result link only through the owner's leased unsent-stage path. Attempted stages require receipt reconciliation before any fresh reading or selection.
4. Interpret the current goal and return its sealed clarification request when needed.
5. Prepare the first search using an injected host provider policy and the existing source-bound query planner, or read/select a fresh candidate link under the owner operation.
6. Record a confirmed native visit, then repeat within the retained task-wide navigation limit.

Fresh candidate reading and asynchronous link selection now share one serialized owner operation. Cancellation and the exact goal are rechecked after selection, and the candidate batch is validated against the actual current page even when selection returns no choice. A selected candidate/link must belong to the bound batch. The cache is published only after a final owner/control-epoch check; opening the link still performs its separate native binding and durable dispatch checks.

The owner retains a bounded history of returned initial-search and result-link confirmations inside each serialized child, before the outer operation checks cancellation. Entries contain only kind, operation ID and goal revision. Duplicate receipts cannot add visits. Pause preserves history; retirement clears it and prevents late publication. The driver accepts only an extension of its prior history, recovers a child completion lost at the return boundary, and retains order and the navigation limit across Resume and accepted answers. These entries are in-memory historical facts, not a persistent general action ledger or verified offer evidence.

Uncertain actions, journal mismatch/storage failures and changed-page failures retain the research request through the existing user-intervention result. Authentication and browser-admission failures continue through the host's typed login/control handling. The driver cannot perform implicit handback. A missing provider, query, selected link or exhausted navigation limit also leaves the original goal pending. It never returns a completed research answer.

The navigation coordinator now passes its configured journal-store factory into the research owner, so the same storage behavior and fault injection reach initial-search and candidate-navigation children. Existing callers keep the normal production store by default.

## Prepared regression coverage

Twelve new methods cover:

- Search and multiple selected links through the actual capability executor, preservation of the complete current user request despite unrelated assistant context, retained history on Resume, and no desktop fallback after admission.
- Unsupported/foreign proposals, the host gate, unavailable provider/query, and no browser allocation during a no-effect decline.
- A sealed question answer through capability continuation, retaining the original request/clock and avoiding repeated answer acceptance or initial search.
- Owner capture before a failing admission observer, with continuation using that exact retained owner.
- Pause during a suspended selector, keeping the owner and driver busy until actual unwind and rejecting late effects.
- Manual login and explicit handback, selecting a fresh unsent link under the same goal and operation rather than loading the stale target.
- Refreshing an unsent initial-search starting page without choosing a different query or provider.
- Attempted, uncertain and verified-without-receipt initial stages stopping before fresh reading, selection or dispatch.
- Storage failure after planned, attempted or verified replacement, recovering only confirmed native facts.
- Foreign/repeated admission and continuation, permanent retirement, and a navigation limit preserved across Resume.
- Unobserved link IDs and actual page drift during selection, rejected before navigation.
- Pause or retirement after a child confirms either the search or a result link but before its outer return: retained visits still consume the limit, and retired history cannot resume.

The provider and link-choice policy in these cases is a controlled fixture. It does not qualify model selection, source compliance, real ticket relevance, authentication-provider compatibility or complete answers. The fixtures use native owned-browser components and loopback pages when eventually executed; none ran at this checkpoint.

## Checks actually performed

Five changed Swift files passed syntax-only parsing. Xcode project registration passed `plutil -lint`; the new production and test files are included in their targets. Whitespace and source-inventory checks passed. The [focused inventory](browser-research-driver-inventory.json) selects 200 methods; the default selects 883, twelve more than the parent. These counts identify reviewed source methods, not passing assertions. No new JavaScript was introduced.

**No typechecking, builds, tests/assertions, inference, app launches, browser/computer-use activity or live E2E ran.** The installed app and model/runtime assets remain unchanged. Existing qualification evidence does not qualify this new source.

## Remaining repair sequence

1. Implement host provider/site policy that respects the complete goal and source restrictions, and the local model adapter for choosing a relevant next link. A model-selected arbitrary URL or fixture-style first-result shortcut is not sufficient.
2. Compose those policies and the concrete driver in the default loader. It currently creates the native capability executor without this driver, so normal installed-app research is not enabled by this checkpoint.
3. Add general search/site/form/date/choice actions and a complete ordered ledger with recovery across process restart or lost browser state. The navigation history here cannot reconstruct arbitrary task state.
4. Verify whole-goal and accepted-answer semantics, relevance, dates, locations, availability, quantity, prices/fees and source-associated offers across pages. Accumulate evidence, qualify public links and produce complete supported answers; a candidate or receipt is insufficient.
5. Qualify current host/phone routing, admission, non-DOM/failed pages, active login windows, control during unanswered questions, empty-session presentation, Stop and explicit Resume. Live travel/concert/movie E2E requires later explicit user permission.
6. Evaluate alternative models or use the authorized RTX 3080 desktop for adaptation when measured model failures justify it. SSH access previously timed out before authentication; hardware/toolchain inspection and connection details remain pending. Preserve held-out sets and separate app defects from model failures. Mac performance and 8 GB/thermal qualification remain a later phase.

Dependencies: [binding recovery](BROWSER_BINDING_RECOVERY_REVIEW.md), [initial-search refresh](BROWSER_INITIAL_SEARCH_REFRESH_REVIEW.md), [browser admission](BROWSER_ADMISSION_REVIEW.md), [initial search](BROWSER_INITIAL_SEARCH_REVIEW.md), [query planning](BROWSER_SEARCH_PLANNING_REVIEW.md), [capability routing](BROWSER_RESEARCH_ROUTING_REVIEW.md), [link replanning](BROWSER_RESEARCH_REPLANNING_REVIEW.md), [question transport](BROWSER_CLARIFICATION_TRANSPORT_REVIEW.md) and [research owner](BROWSER_RESEARCH_OWNER_REVIEW.md).
