# Refresh an unsent search after login changes its starting page

Source checkpoint: changes based on `7980c6f`. This is a source implementation with prepared verification, not runtime qualification.

## Problem and first principles

An admitted browser can hold a planned search when the user takes control. Login or another manual navigation can then replace its starting page. Explicit Resume correctly refuses to dispatch from that stale document, but previously there was no way to refresh the unsent stage without abandoning it.

The user's goal and search request have a different lifetime from the page on which execution begins. Refreshing that page must preserve the original query, provider, complete goal, clock, browser session and operation identity. It cannot make an already attempted request safe to repeat. A missing receipt alone cannot prove that no request was sent, and a failed journal write can leave a replacement file visible without confirming its durability.

## Implemented source path

The retained research owner exposes `refreshInitialSearchStartingPage()` separately from `resumeInitialSearch()`. It requires an idle, active owner with no unanswered question or pending candidate-link stage and the exact retained goal revision. It uses the same serialized operation and cancellation controls as the rest of research. It does not perform handback itself, select another query/provider or navigate.

The initial-search stage acquires its cross-instance execution lease before observing the browser and holds it through journal replacement and cancellation unwind. It validates the captured native session, then requires both an absent/planned journal and no native attempt for the operation before reading. It acquires the actual current document, performs normal authentication-aware page observation, and rechecks ownership, cancellation, the document and native attempt history afterward.

Only the starting-document binding may change. Stable record and operation IDs, original root prompt digest, complete request and sealed session remain fixed. The binding includes the native document context/generation/operation/URL and isolated document identity; a transient page-snapshot nonce does not change it. Repeating refresh on an unchanged saved document returns `unchanged` without another write. A completed retained stage returns `noPendingStage`.

Attempted, uncertain or verified rows, and native attempts even beside a missing/planned row, return `requiresReconciliation` before further page reading. Normal search recovery still uses exact native receipts rather than issuing another request. Native navigation now records attempted operation IDs immediately before dispatch and refuses to reuse them, including failed loads without receipts. The set is bounded at 64 per ownership lifetime, like the existing receipt bound, and clears only when claiming a different owner. Existing observed-navigation refresh also consults this combined history. Stop/reclaim cannot grant an old stage a new session: its sealed identity is invalid.

Before replacement, the stage retains its current and proposed starting points. A failed write keeps those two known possibilities. A later fresh store read, followed by acquisition of the exact execution lease, may resolve only the known binding actually visible in the journal. An unknown binding fails closed. This resolves metadata, not dispatch permission: an eventual request still requires current native/session checks and a confirmed durable attempted write. The production store has no rollback path.

A successfully committed replacement updates the retained starting point before surfacing a late Pause, so memory cannot remain bound to the old page while the journal names the new one. Retirement remains permanent. Failed observation cannot publish a replacement, and asynchronous cancellation keeps the operation slot occupied until unwind.

## Prepared verification and checks performed

Seven new XCTest methods cover:

- Durable attempted, uncertain and verified records stopping refresh before reading.
- Successful and failed native-only attempts beside a planned journal, with duplicate native dispatch refused.
- Execution-lease exclusion during observation, cancellation without replacement, and explicit later retry.
- Committed replacement followed by late cancellation or retirement.
- Failed post-rename writes with either known binding visible during fresh recovery.
- Rejection of a third, unknown journal binding before reading or dispatch.
- Stop, close and same-root reclaim failing the captured-session check.

The existing owner/admission case now continues a real page change during Pause through explicit refresh and a separate single search dispatch. It checks the unchanged complete goal and stable journal/operation identity, no request from refresh, an unchanged refresh no-op, and completed-stage behavior. Fixtures use controlled loopback responses and injected storage/cancellation boundaries when eventually executed; they were not run here.

Five changed Swift files passed syntax-only parsing. Xcode project syntax, whitespace and both source inventories passed. The new test file is registered in the Xcode target. The [focused inventory](browser-initial-search-refresh-inventory.json) selects 175 methods; the default selects 864, seven more than the parent. Counts reflect source registration, not passing assertions.

**No typechecking, test/assertion execution, builds, model inference, app launches, browser/computer-use activity or live E2E ran.** No new embedded JavaScript was introduced. Installed app, model/runtime assets and historical qualification evidence were untouched. About 15 GiB was free, so no obsolete generated-file cleanup was needed.

## Remaining repair sequence

1. Select providers/sites consistently with the complete goal and source restrictions, then implement the concrete research driver and default-loader composition. The driver must explicitly choose observation refresh versus attempted-action reconciliation; this capability alone does not establish relevance or completion.
2. Complete additional search/form/date/choice actions, an ordered action ledger, source-associated offer/date/availability/price/fee verification, cross-page accumulation and qualified public links and answers.
3. Review ambiguous failed binding replacement in the older candidate-link replanning path, which is separate from this initial-search implementation.
4. Qualify owner/host/manual-login controls, including authentication during refresh, active sign-in windows, pending DOM work, changed pages, failed/non-DOM pages, and login during an unanswered question.
5. After explicit permission, compile and execute controlled driver/runtime cases, then run travel, concert and movie tasks on real sites. Current model prompts, live site behavior and performance on 8 GB Macs remain unqualified; performance optimization is deferred.

Related checkpoints: [browser admission](BROWSER_ADMISSION_REVIEW.md), [initial search](BROWSER_INITIAL_SEARCH_REVIEW.md), [research replanning](BROWSER_RESEARCH_REPLANNING_REVIEW.md), [research routing](BROWSER_RESEARCH_ROUTING_REVIEW.md) and [retained owner](BROWSER_RESEARCH_OWNER_REVIEW.md).
