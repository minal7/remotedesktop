# Durable initial search under the retained research goal

Source checkpoint: changes based on `2104537`. This review records implementation and prepared verification. It does not qualify the runtime, model, websites or installed app.

## Problem and first principles

The search planner could propose source-bound terms, but no retained action connected those terms to the first browser request. Passing a query to ordinary navigation would lose the distinction between the complete goal and the selected search terms. Rebuilding an interrupted action from new terms, provider, clarification ID or browser identity could also create a second request instead of reconciling the first.

The first search is one action within research. Its stable identity must belong to the original task, while its binding records exactly which goal revision, query, destination and native session were selected. A durable attempt must precede dispatch; resuming an attempt must inspect existing evidence without calling the effect API. A receipt establishes only historical navigation, not useful results, successful login or task completion.

## Implemented source path

`ComputerUseBrowserSearchProvider` is supplied by host code/configuration; it is never decoded from model output and has no automatic provider choice. It accepts an HTTPS endpoint or an HTTP loopback fixture endpoint, with no credentials, existing query or fragment. Endpoint and parameter lengths are bounded. A single host-selected parameter receives the query as percent-encoded UTF-8 bytes, including literal plus signs, ampersands, hashes, percent signs and equals signs. These cannot become spaces or additional query parameters through form-query decoding. The resulting URL passes the native navigation limits.

`ComputerUseBrowserInitialSearchRequest` binds the provider and constructed destination to the exact goal interpretation and query proposal. Empty queries, foreign revisions and mismatched interpretations are rejected. The complete canonical goal, exact answers and original clock remain distinct from the query. Request/provider debug descriptions omit their contents. Provider selection semantics and source restrictions remain the future driver's responsibility; constructing a provider does not prove that using it meets a request.

`ComputerUseBrowserInitialSearch` retains one immutable request and the actual sealed native session. Its journal key and operation ID depend on the original task ID and fixed purpose, excluding query, provider, answer, clock and session changes. Its binding digest includes the exact request and session; its prompt digest retains the canonical root. A changed binding finds the original journal and fails instead of creating another effect namespace. Journal files contain identities/status, not URLs or query text.

The existing journal store holds an execution lease across dispatch and callback completion. A planned record is written first. An unused-session check runs before navigation; the native adapter checks the exact session again before presentation, before the effect callback and after it. The callback writes the durable attempt before any WebKit load. Thus a same-task Stop/reclaim during a persistence callback cannot authorize a request against retired session identity.

An attempted, uncertain or verified record takes a receipt-only recovery path. No native effect API runs there. A matching historical native receipt may confirm the record even if the browser has since moved through login or another page. Missing receipt evidence remains uncertain. Failed writes after replacement are handled by the store's existing ambiguity rules: a subsequent fresh store reads the visible record, and an attempted/verified record cannot fall back to a fresh load. Late confirmation can be retained without returning success after Pause or retirement.

The research owner exposes initial dispatch and explicit pending-stage continuation through its existing serialized operation boundary. It retains the stage before storage or effects, preserves it through Pause, and includes it in the pending-navigation gate for queries, interpretations, questions, candidate reads and candidate navigation. A caller cannot replace it with another query/provider. The owner exposes whether initial search is unprepared, pending or confirmed, so the driver can continue after handback without proposing another first request; confirmed denotes a historical navigation receipt only. Accepted answers before initial dispatch retain the original browser root and clock. After receipt reconciliation, actual page/authentication observation still precedes candidate reading; selected links use the existing research navigation journal.

## Prepared verification and actual checks

Ten new methods prepare:

- Exact Unicode/punctuation query transport, full-goal binding, redaction and invalid provider/parameter/empty-query rejection.
- Durable planned/attempted records before the first request, historical receipt replay after the page moves, adapter replacement and journal content limits.
- Pause after a planned write versus Pause after the durable attempt, retained query/provider selection and explicit empty-session handback.
- Failed and cancelled first loads remaining uncertain when a new adapter attempts recovery.
- Storage failures after each of planned, attempted and verified replacement, with no duplicate dispatch or false success.
- Rejection of changed query, provider, original goal and native session against the original journal key.
- Rechecking actual native session identity after a same-task Stop/reclaim in the attempt callback.
- Refusal to replace an existing page or claim another task's browser through the first-page action.
- Exclusive execution through a held native load, cancellation on owner retirement and refusal to treat released exclusion as fresh effect authority.
- A retained exact clarification answer through initial navigation, visible authentication, explicit same-session handback, fresh candidate reading and journaled candidate-link navigation. The fixture does not verify offer semantics or claim a completed research answer.

The [focused source inventory](browser-initial-search-inventory.json) selects 157 methods. The default selects 846, ten more than the parent. Both new Swift files are registered in the Xcode targets. Four changed Swift files pass syntax-only parsing; project syntax, the one fixture script's syntax, both source inventories and whitespace checks pass.

**No typechecking, test/assertion execution, builds, model inference, app launches, browser/computer-use activity or live E2E ran.** The prepared cases are not runtime evidence. The installed app and model/runtime assets are unchanged. Approximately 15 GiB remained free; no obsolete generated-file cleanup was needed.

## Remaining repairs

1. Implement deliberate browser admission for successive research requests. This stage currently dispatches only from the same unused native session. The current owner does not claim another task's existing browser, and a used session cannot become unused through Stop/claim. The driver needs a reviewed way to transfer/reuse existing browser context or begin a new session without breaking manual login control or silently discarding account state. This is an integration requirement, not proof supplied by first-page dispatch.
2. Choose the provider/site consistently with the complete goal, including source restrictions, and qualify useful queries against actual phrasing, relative dates and locations. No default provider or concrete research driver is supplied by this repair.
3. Connect the concrete driver and default loader, additional search/form/date/choice actions and the complete ordered action ledger. Define explicit replanning of a proven-unsent initial stage where appropriate. Attempted/uncertain effects retain reconciliation requirements.
4. Verify source-associated offers, availability, dates, price/fee conditions, public links and cross-page answers. Initial navigation, a current candidate and a successful login handback are insufficient completion evidence. Login while a question is unanswered and pre-admission Pause need full driver/control qualification.
5. After explicit permission, compile and execute controlled source/owner/driver/runtime cases, then exercise travel, concert and movie research on real sites. Presentation/cancellation behavior, provider behavior and all current model prompts remain unqualified. Performance and 8 GB/thermal qualification remain deferred.

Related checkpoints: [empty-session handback](BROWSER_EMPTY_SESSION_REVIEW.md), [query planning](BROWSER_SEARCH_PLANNING_REVIEW.md), [research routing](BROWSER_RESEARCH_ROUTING_REVIEW.md), [research replanning](BROWSER_RESEARCH_REPLANNING_REVIEW.md) and [retained owner](BROWSER_RESEARCH_OWNER_REVIEW.md).
