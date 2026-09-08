# Resume before the first browser page

Source checkpoint: changes based on `979b74e`. This is a source repair with prepared verification, not an executed browser qualification.

## Problem and first principles

A workflow must allocate an actual browser session before binding its effects to durable identity. Pause can arrive after that allocation and before the first page loads. Previously, native handback and the retained research owner always required an existing document, so this legitimate interruption could not resume. Goal and search planning also demanded page observation whenever the browser had been claimed, even if it had never navigated.

An absent document alone cannot distinguish this state from a failed or cancelled request. Clearing documents, receipts or task ownership must not erase the fact that the native session was used. Likewise, native proof that a request never reached WebKit cannot erase an already durable uncertain action: the journal retains authority over reconciliation.

## Source change

The native browser records navigation activity monotonically for each WKWebView lifetime. Native dispatch marks activity before creating the pending load. Main-frame navigation policy, provisional navigation and URL observation also mark activity. Failure, cancellation, Stop and subsequent claims do not reset the record. Only allocating a new WKWebView starts a new record, together with a new session identity.

`isUnnavigatedSession` validates the sealed task, browser object/session, ownership epoch and action gate. It then requires no recorded navigation activity, URL, load, pending navigation/DOM operation, document, receipt, loaded-page identity, retained page observation or sign-in window. It is a narrow native state check, not page evidence, a receipt, a login assertion or journal authority.

Explicit handback may present that same unused browser. Presentation has a bounded two-second focus wait with cancellation, actual session/ownership and unused-state checks around suspension. Final handback still requires the original presentation policy and session. Any activity that begins during the wait invalidates the empty path. Headless fixtures use the existing headless presentation policy. Sessions containing pages continue through the existing document/observation handback; this change does not waive authentication observation for them.

The retained research owner uses this distinction before goal/query planning and during explicit Resume. A truly unused session permits planning from the complete canonical user goal without fabricating a document. Used sessions still require native page/authentication observation. A captured session that disappears is rejected before new inference. Candidate reading always requires an actual observed page. The owner's operation slot, Pause epoch, cancellation, exact answers, original clock and task root remain in force.

## Prepared verification

Eight new methods cover:

- Repeated unused-session handback retaining identity without a document, receipt or DOM read, and rejection when the action gate is closed.
- Rejection of missing/stale requirements after Stop, close or ownership replacement, even when the replacement is also empty.
- Failed and cancelled first loads remaining used sessions, with no handback-triggered reload.
- An action durably marked uncertain before native dispatch: empty handback preserves the journal and cannot cause another dispatch.
- Task evidence being cleared after a successful load without making the retained WKWebView unused.
- Goal/query planning and exact clarification answers through empty handback, while candidate reading and lost-session planning remain blocked.
- A newer Pause cancelling an empty handback without a late completion clearing it.
- The actual host/capability routing boundary continuing its retained controlled research driver after Pause before the first page, without readmission or loss of the original goal/clock.

The [focused inventory](browser-empty-session-inventory.json) selects 147 source methods, including populated-page/login and session-replacement regressions. The default inventory selects 836, eight more than the parent. Existing test files already belong to the test target; no project registration changed.

Five changed Swift files pass syntax-only parsing. Both source inventories and whitespace checks pass. **No typechecking, test/assertion execution, builds, model inference, app launches, browser/computer-use activity or live E2E ran.** Prepared tests do not establish runtime correctness. The installed app, model/runtime assets and historical evidence remain unchanged. About 16 GiB of disk space was available; no generated-file cleanup was needed.

## Remaining work

1. Implement journaled initial search dispatch under the original research root, retaining the selected query/destination through interruption. This native check cannot authorize replacement or replay of attempted/uncertain stages; the dispatcher must obey the durable/native effect records.
2. Choose the initial provider/site consistently with the full request and source restrictions. The source-bound query proposal alone supplies neither a destination nor semantic coverage.
3. Implement the concrete research driver and default-loader composition, further form/date/choice actions and the complete ordered ledger. Connect retained candidate navigation and fresh, proven-unsent reselection after login without replacing the canonical goal.
4. Verify source-associated offers, dates, availability, prices/fees, public links and complete answers across pages. Login during an unanswered question and pre-admission Pause still need complete driver/control qualification.
5. After explicit permission, compile and execute controlled cases, qualify actual window presentation and cancellation, then exercise travel, concert and movie research on real websites with manual account login and explicit handback. Performance and 8 GB/thermal qualification remain deferred.

Related source checkpoints: [search planning](BROWSER_SEARCH_PLANNING_REVIEW.md), [research routing](BROWSER_RESEARCH_ROUTING_REVIEW.md), [research replanning](BROWSER_RESEARCH_REPLANNING_REVIEW.md) and [research owner](BROWSER_RESEARCH_OWNER_REVIEW.md).
