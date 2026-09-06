# Require evidence for each requested contact query

Parent source: `24b6d2d`. Status: source repair and regression registration only. No build, test execution, inference, app launch, computer-use activity or installed-app replacement. Performance optimization and live website qualification remain deferred.

## Failure and resulting behavior

`Find Jordan Lee and Avery Chen in Contacts` previously produced one completion obligation: the Contacts domain. A valid result for Jordan alone could satisfy it. The existing result verifier checked whether returned fields matched the planner's query; that query was allowed to be a substring of a requested entity. Neither check proved coverage of the user's requested people.

The structured planning state now retains ordered Contacts query requirements compiled from the current trusted instruction before any planner proposal. Supported clauses include named lookups, possessive contact/phone/email requests, field requests for named entities, matching-name searches, conjunction/comma lists and separate explicit read clauses. Double-quoted and curly-double-quoted names keep internal conjunctions and commas as data. The compiler consumes each supported Contacts clause and rejects unrepresented entity wording; it does not derive the requirements from model calls or returned records.

For a compiled request, a proposed Contacts query must match a full required query before local access. Query identity folds case and whitespace but preserves accents and punctuation. A query for `Lee` cannot satisfy `Jordan Lee`; `Ann Marie Lee` cannot silently replace `Ann-Marie Lee`.

Completion requires a matching typed host projection for every required query. Results are assembled in request order, independently of tool-call order. Multiple-query answers label each query, including verified empty results, so an absence is not attributed to the wrong person. Single-query answers retain their existing host projection. All admitted results must belong to the compiled query set. Existing domain coverage, private-read authorization, exact arguments, bounded/untruncated results, consequential-action guards and fallback ownership remain in force.

The planner receives the host-reviewed queries as JSON data, alongside the original task and local results, to make coverage visible without granting new authority. The contract accepts at most nine distinct queries, leaving room for a terminal proposal inside the existing ten-step budget.

## Boundaries

This is a Contacts scope compiler, not the complete shared task graph. Other explicit read domains keep their current independent checks. Unknown residual clauses prevent Contacts completion. Negated Contacts reads or requested-entity denials also prevent completion rather than silently being discarded. Limited declarative quoted labels are recognized as data, and the existing supported negated edit instructions remain compatible.

If a Contacts scope cannot be compiled, the old private-read authorization can still admit a relevant lookup, including a lookup needed to prepare Mail. Such a read cannot establish read-only whole-task completion. The original request reaches the existing fallback when the planner stops. Mixed requests such as `Jordan's phone number and Avery's email address`, indirect references such as `then find Avery`, conditions and unsupported names/phrasing remain unresolved rather than being reduced to the first entity. Future work must compile them, clarify ambiguity where necessary, and bind requested fields and constraints explicitly. A narrow grammar is not a claim of general natural-language correctness.

Matching a query is not proof of a unique real-world person, freshness across separate reads, exhaustive results beyond the requested/helper limit, or the completion of another action. Complete structured/native/visual composition, approved-action versus task outcomes, entity disambiguation, private-data field minimization and durable read evidence remain open.

## Prepared regression coverage

Six new production-executor methods cover:

1. Either of two requested people missing after the planner proposes completion.
2. Both people read in reverse order across four supported phrasings, with answer order and host-reviewed planner query data asserted independently.
3. One person's lookup returning no matches, with the absence labeled for that query.
4. Partial or punctuation-changed queries rejected before local access.
5. Uncompiled alternatives, inherited entities, mixed field ownership and conflicting read denials remaining incomplete after a valid first lookup.
6. A quoted organization name with an internal `and`, retained as one query.

The recording MCP fixture can now return an ordered sequence of typed results for repeated calls to the same tool. Its existing fixed-result behavior remains available. The new cases use no real helper, account, app or model.

Source inventory checks match **562 default** and **17 focused** method identifiers; whitespace checks pass. See [the focused inventory](contact-read-requirements-inventory.json). All changed Swift files already belong to the project. No compilation or runtime behavior has been verified for this patch.

## User-directed web browsing and account handoff work

The user's additional requirement is to handle browsing tasks and hand control over for account login. Retain that scope while finishing completion repairs; the earlier live-test pause still applies.

Source review confirms that `HostComputerUseManager` handles `.userInterventionRequired` as a pause, retains the original execution context and blocks automation while the person signs in. It does not mark the task complete. Existing direct-input intervention also revokes action permission before cancelling execution.

The owned WebKit browser still has concrete gaps:

- A navigation with no pending automation navigation invalidates `document`; its finish callback creates no new current-document record. `acquireCurrentDocument` requires the old valid record. A manual login redirect therefore cannot be reacquired through that API after handback. A manual page observation must be represented separately from proof that an automation step executed.
- Popup navigations are cancelled when `targetFrame` is absent, and no popup/login window flow is implemented. Some provider sign-in paths consequently cannot proceed. Supporting them requires visible ownership, origin/context continuity and a clear return to the task page.
- The browser uses a nonpersistent website data store. It keeps the same WebKit instance across ordinary pause, but closing/releasing it loses that in-memory context. Do not silently substitute another browser/session during handoff. Persistent account storage is a separate product decision; copying Safari/Chrome cookies is not a handoff implementation.

Repair order: explicit user/automation control state; retain the visible browser while the user controls it; record independently observed manual navigation without minting task-action receipts; reacquire fresh page/target references only on explicit authenticated handback; re-evaluate remaining goal obligations; support reviewed login popup flows; verify resume/Stop/disconnect/close/restart behavior through the host and phone. Treat the user's handback as permission to resume, not proof that login succeeded. Confirm the resulting account/page state from fresh observations and keep authentication secrets out of model observations and task logs. Then complete browsing navigation/search, dates/location widgets, extraction and source-backed results. Real travel, concert and movie runs remain subject to later explicit permission.
