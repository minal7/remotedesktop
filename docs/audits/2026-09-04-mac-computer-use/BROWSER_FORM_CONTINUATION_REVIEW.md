# Verified form edits must constrain the eventual query

Date: 2026-09-07. Parent source: `818f4fb`. Source implementation and syntax review only. Builds, assertions, models, application launches and live websites remain paused at the user's request.

## First-principles defect

A successful edit is a historical fact. A search request is a later effect. Between them, page code or a person can change a field. Capturing the current query faithfully does not establish that it still contains the requested values. A completed journal also cannot establish current state, and matching text cannot establish that the requested input operation happened.

The previous [native query capability](BROWSER_FORM_QUERY_REVIEW.md) already compared a prepared query with its later state. It did not compare preparation with the intended results of the earlier edits. It could therefore bind and open a newly changed value. It also had no task-level reason to reject a query that silently omitted an edited unnamed field or an edited field in another form.

The continuation needs four independent things: the exact retained task, its expected final values, the original document's input receipts, and a query that actually includes every edited field. Navigation is still an intermediate fact; it cannot establish that tickets matching the original request were found.

## Source repair

1. `ComputerUseTextTask.verifiedContinuation()` issues immutable, non-Codable requirements only when every journal step is verified. It does not run the task, repair unfinished steps, invoke a planner, or dispatch input to obtain those requirements. The type has a file-private constructor and a value-free standard description.
2. The requirements bind the task ID, original prompt digest, complete text contract digest, ordered effect identities from the actual compiled execution contract, edited target set and exact final values. Unchanged-field constraints remain part of the final values. A recovered verified journal can produce historical requirements, but the browser must independently check live receipts and values before accepting them.
3. `ComputerUseBrowserTextTarget` maps only its original retained host field IDs to its retained DOM IDs. It checks the owned document, isolated document nonce and task ID. It does not rediscover fields or transfer authority to another browser, task or answer. Normal retained-field reobservation and page snapshots preserve input receipts; fresh discovery cannot reconnect them.
4. The browser receives a bounded private requirements object. Its digest includes the original continuation, browser context, generation, task, document nonce and field mapping. The prepared navigation payload includes this digest. Exact values, option IDs, input receipts and encoded private queries stay outside planner context and standard descriptions.
5. At preparation and again before native navigation, one synchronous isolated-world operation verifies the complete bounded requirements shape, every original input receipt and every required field's exact value. Choice comparison uses the retained selected-option identity, while native query encoding uses the corresponding server submission value. UTF-8 distinctions such as composed/decomposed text are not normalized into equivalence.
6. Query construction records which native members actually contribute entries. Every edited target must contribute to the selected form. Unchanged fields may be outside that form, but must still satisfy their exact constraints. Disabled, unnamed, unrelated or otherwise omitted edited controls cannot silently disappear from a verified query.
7. Revalidation uses the private requirements saved during preparation. A caller cannot replace or omit them to weaken a prepared target. The requirements digest must match. Lost receipts, retired fields and changed outside-form constraints block navigation even if the form's current encoded query is otherwise identical.
8. `ComputerUseNativeTextExecutor` retains the browser adapter alongside its immutable task and exposes query preparation for that exact task/prompt. It rejects missing or unfinished tasks, concurrent execution, foreign prompt/task identities, cancellation and user control. It clears the paired adapter when replacing the task. This path only prepares a target; it neither automatically submits nor treats form-edit completion as completion of a browsing goal.

Requirements are limited to 16 retained fields, eight unique input operations, 8 KiB per expected value and 64 KiB of total expected values. Existing query/member/entry bounds still apply. These limits are capability bounds, not evidence of acceptable resource use.

## Prepared regression coverage

Six new `ComputerUseBrowserDOMTests` methods cover:

- The native executor's retained transaction through exact text and choice edits, an outside-form unchanged constraint, query preparation, native navigation and confirmed replay. Expected request names/values and input-event counts are independent assertions. No replanning, extra input or form events should occur during continuation. Missing task, wrong task/prompt and user control must block preparation.
- Planned, attempted and uncertain journals cannot issue continuation requirements. A recovered verified journal with matching field values still lacks document-owned receipts and must be rejected. One completed input cannot stand in for a second identical requested input. Resuming and completing that second operation permits the same requirements without replaying the first or using journal flags as receipt evidence.
- Changed edited text and byte-different unchanged text outside the form, both before preparation and after preparation. The capture-only query primitive remains usable as an explicit current-state control, demonstrating why task requirements are necessary.
- An unnamed edited field and an edited field belonging to another form. The native entry-list primitive can capture these forms; the verified continuation must reject their omitted edits.
- Field rediscovery and receipt loss before preparation or after preparation, with unchanged current values and no navigation attempt.
- An identical foreign browser document and a clarification ownership transfer. Retained values and DOM receipts cannot rebind the completed task's authority.

The [focused source inventory](browser-form-continuation-inventory.json) selects **168** methods. The default source inventory selects **697**, six more than the previous 691. Five changed Swift files pass syntax-only parsing; embedded JavaScript syntax, both source inventories and whitespace checks pass. **No assertions ran and no typecheck occurred.** The prepared cases are not runtime evidence.

## Remaining work and qualification order

1. Integrate a whole-browser task compiler and driver that retain the entire original request and separately authorize form edits, selected submission and navigation. The new executor seam is available to that driver; normal natural-language routing does not yet select this multi-step continuation. The existing capture-only query primitive is not sufficient authority for a goal-directed search.
2. Journal and reconcile query/navigation effects through the durable task engine. The prepared query and browser-owned receipts are currently in-memory; process restart, document loss and uncertain server outcomes must not trigger blind resubmission or reconstruction from matching labels.
3. Preserve the remaining goal through login takeover and explicit handback. Reobserve the current page/account, replace stale target references under the retained task, and reconcile prior facts before any new effect. Do not reuse a pre-login query just because its task ID still matches.
4. Implement and qualify DOM submission, JavaScript forms, POST, custom date/location controls and supported provider behavior separately. This change continues to open a native GET destination without dispatching page submission events; a website may require different semantics.
5. Verify complete travel/concert/movie results: requested dates, locations, counts, availability, prices and fees, and usable public source links. Field edits and a successful query navigation satisfy none of these result requirements on their own.
6. With later explicit permission, typecheck/build and run controlled regressions before real-site scenarios. Keep the existing model holdouts untouched. Installed host/phone/login behavior, the failing OCR gate and 8 GB/thermal qualification remain open; correctness repairs precede performance optimization.

Storage check during this repair found about 15 GiB free. No obsolete generated file needed removal, and these checks created no build or result bundle. The user's standing cleanup authorization remains recorded in `TODO.md`.
