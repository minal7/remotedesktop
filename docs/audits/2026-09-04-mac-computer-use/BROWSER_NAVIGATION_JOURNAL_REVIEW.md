# Durable attempts for observed browser destinations

Date: 2026-09-07. Parent source: `6819ea6`. Source repair only. Builds, typechecking, test execution, model runs, application launches and live websites remain paused.

## First-principles defect

An HTTP request may reach a website even when its caller never receives a result. A browser document that looks unchanged cannot establish that no request was sent. In-memory replay protection also cannot establish this after an executor or browser is replaced. The host needs durable evidence before allowing the request, and recovery must inspect evidence without calling an API that might send the request.

The [observed link/query capability](BROWSER_FORM_QUERY_REVIEW.md) already retained in-memory attempts and native receipts. The [form continuation repair](BROWSER_FORM_CONTINUATION_REVIEW.md) bound queries to the intended edits and input receipts. The host's observed-destination entry point still forwarded directly to the in-memory browser primitive without its own durable effect record. Literal URL navigation used the generic task journal separately; that did not cover observed links and queries.

## Source repair

1. `ComputerUseBrowserNavigationTask.openObservedDestination` now owns a per-effect record through the existing `ComputerUseTaskJournalStore`. Its host-tools entry point requires the original prompt digest and stable operation ID. The caller remains responsible for authorizing the operation as part of the complete user request. Neither a page ID nor the new journal authorizes an arbitrary action.
2. The lookup key binds root task ID and operation ID, excluding browser context, document and payload. A replacement browser or newly prepared reference therefore finds the existing record. The immutable record separately binds the prompt and exact target payload, including its context, snapshot, destination and optional verified-edit requirements. Changed prompt, target or browser context cannot become a fresh operation under the old ID.
3. The record contains hashes, the operation ID and status only. Exact URLs, query values, hidden server fields and private DOM objects are absent. Observed-destination records have their own subdirectory and cannot overwrite the literal-navigation task or native-text journal.
4. A cross-instance execution lease covers the entire call, including asynchronous DOM validation, navigation, cancellation unwind and final persistence. Compare-and-advance writes reject stale writers. A second executor cannot reconcile or dispatch while the first still owns the effect.
5. Planned identity is saved before validation. The attempt is atomically saved and synchronized after fresh DOM validation but before WebKit's load. The native dispatch callback can now throw: storage failure cannot authorize the load. The caller's effect notification runs only after the durable attempt succeeds. Control, cancellation, presentation and the exact prerequisite document are rechecked before loading; reacquiring the same task ID cannot revive a document retired during the callback.
6. A read-only browser receipt method checks the exact observed target, operation, task and context. It cannot load, rediscover a page, or infer a receipt from equal URLs. Receipt retrieval deliberately does not require current control so that a late confirmed fact can still be saved after Pause/Stop; effect admission and successful return continue to require control.
7. Attempted/uncertain recovery uses only that read-only receipt method. Missing receipt means reconciliation is required, with no call to the effectful API. A verified journal also cannot recreate a lost browser document or issue a replacement request. Confirmed historical receipts can be returned while a later page is current, so callers must independently establish any current-page prerequisite.
8. A fresh successful load is marked verified only after the browser's independently retained native receipt matches. Late confirmation may update the durable record while the interrupted caller still receives its original cancellation or ownership error. Persistence failure after the request cannot be turned into success; the durable record and any native receipt must be reconciled on a later call.

The journal is an effect record, not a whole-goal result or a serialized browser session. It does not persist a usable document token, account session, full task graph or remaining goals. A verified record means this bound navigation was confirmed, not that the requested tickets were found. The raw browser method remains the internal primitive; the host-tools path now goes through the journaled facade.

## Prepared verification

Seven new `ComputerUseBrowserDOMTests` methods cover:

- Both observed links and native form queries, with the durable attempted record readable before the first server request, private values absent from serialized records, replacement-executor replay, historical receipts after later navigation, and refusal to recreate lost receipts from a verified record.
- Prompt, payload and replacement-browser rebinding under one stable operation ID, preserving the original record and sending no replacement request.
- User takeover, Stop and a retired prerequisite with the same task ID reacquired at the dispatch boundary, an uncertain durable attempt and replacement-executor refusal to repeat the effect path.
- Storage failure after each of planned, attempted and verified replacement writes. The first two cannot load; the third cannot publish success. Reconstruction distinguishes an unsent plan, an ambiguous attempt and a retained native confirmation.
- Concurrent facade instances using separate stores while the first native request is still held open. The second receives the execution-lock failure and cannot alter the first record or send another request.
- Native confirmation followed by cancellation and lost control during document-identity observation. The late fact is durable, the caller remains cancelled, and reconciliation sends no second request.
- Authentication or changed page authority during fresh validation. These leave an unsent planned record and no effect notification/request.

The existing verified-form executor case now routes query navigation through this durable facade, connecting retained edits, native query preparation, durable request admission and confirmed replay in one prepared component fixture.

The [focused source inventory](browser-navigation-journal-inventory.json) selects **188** methods: the preceding browser selection, seven new methods and the 13 existing journal-store methods newly included in this focused gate. The default source inventory selects **704**, seven more than the previous 697. Four changed Swift files pass syntax-only parsing; both source inventories and whitespace checks pass. **No assertions or typecheck ran.** Existing store tests are selected evidence requirements, not freshly executed evidence.

## Remaining repair order

1. Connect the full browser task compiler/driver to the host capabilities. Preserve the complete original request and stable step identity across planning, edits, observed navigation, approvals and login. Normal natural-language routing does not yet select the complete sequence covered by these prepared component fixtures.
2. Retain and verify the remaining task requirements, with page/account prerequisites distinct from historical navigation facts. A per-effect journal cannot decide the next authorized action or establish whole-task completion. Do not generate new operation IDs merely to evade uncertain recovery.
3. Define explicit reconciliation after document/session loss. The new durable record prevents automatic replay; it does not restore private DOM references or prove server-side outcomes. Login takeover and explicit handback still need full-goal integration and provider qualification.
4. Implement site-required submission semantics and supported widgets separately. Native GET navigation still does not dispatch DOM submission events or implement POST/JavaScript workflows.
5. Verify returned travel, concert and movie results against dates, locations, counts, availability, prices/fees and selected public sources. Navigation confirmation is only an intermediate fact.
6. After later explicit permission, typecheck/build and run the controlled gate before real-site scenarios. Keep the local-model holdouts unused. Installed host/phone behavior, OCR reliability, 8 GB resource budgets and thermal qualification remain open, with performance optimization following correctness repairs.

About 15 GiB remained free during this repair. No build/result bundles or disposable scratch files were generated, and no cleanup was necessary. Standing cleanup authorization remains in `TODO.md`.
