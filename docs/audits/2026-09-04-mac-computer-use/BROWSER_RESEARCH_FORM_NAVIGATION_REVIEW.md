# Retain form-query navigation under the research goal

Parent: `cb838bd`. This checkpoint connects verified form stages to the existing native GET-navigation journal and connects recovery to the research driver. The default driver still does not choose new form actions or invoke the form planner. The implementation is source-only and has not been compiled or executed.

## First-principles findings

Typing search fields and opening their query are separate actions. A verified edit receipt proves neither that the form was submitted nor that a research answer was found. The next action needs its own stable identity, pending state, original goal and native navigation evidence.

Recovery must also distinguish changed observation metadata from changed intent. User handback can refresh a page's observation nonce without changing the form. Conversely, a hidden form action or an unedited submitted field can change a query while every visible label stays the same. Visible similarity alone cannot authorize a replacement destination.

The existing navigation journal already distinguishes planned, attempted, uncertain and verified loads and can replace a proven-unsent binding under an execution lease. Reusing that boundary avoids a second submission implementation with different replay rules. The missing work was retaining a query intent before preparation, keeping its verified form continuation, and making the parent driver reconcile it before further planning.

## Source changes

- `ComputerUseBrowserResearchFormNavigation` retains the original goal, verified form receipt, exact submitter reference, source observation and original form-stage adapter. The owner retains this object before the first native preparation await. Its operation ID derives from the root task, root digest and form-stage identity, excluding new page/query nonces and destination bytes.
- Native preparation uses the form stage's verified continuation. It checks actual retained fields, final values and native input receipts; no field discovery or model call occurs. The resulting private navigation target is retained before any journal write or load. The existing navigation task persists its planned and attempted records and validates the exact source-bound target before dispatch.
- Retrying an attempted, uncertain or verified query uses the existing journal and original native navigation receipt. It does not prepare a different query or infer a load from an equal page URL. A missing receipt remains unresolved. Repeating a completed intent returns historical navigation evidence and never loads again.
- An already-bound but wholly unsent query can refresh under the existing journal lease and durable/native no-attempt checks. The original document and captured page content must match, except the observation nonce and viewport. The original field adapter and continuation recheck the form. A native comparison then requires the same submitter ID, verified-input requirements digest, source policy and exact UTF-8 destination bytes, including all query parameters. Changed form actions, unedited submitted values or visible context cannot silently replace the intent.
- A failed binding replacement can leave either known target on disk. Both targets remain available for leased resolution against a fresh store. After a failed verified write, recovery uses the visible journal and native receipt without loading again. An interrupted first preparation can refresh its still-unbound observation on a later call; it has not yet invoked navigation, and any existing native attempt prevents preparation.
- Pending form queries count as pending navigation throughout the owner. They exclude new form stages, replacement result-link/initial-search actions, source-policy changes and new clarification answers. Identical calls and explicit resume use the same retained intent; changing the submitter is rejected. Pause retains it. Retirement clears it and prevents late history publication.
- Confirmed query loads enter navigation history as `formQuery`, with the original goal revision and root digest. The driver's existing history synchronization and navigation limit include them. A pending form query is reconciled before result reading or link selection. Pending edits also reconcile first, but currently return an intervention because new form-action selection is still incomplete. Form/query verification failures preserve the original task and do not claim an answer.
- Cancelled query preparation or validation joins any still-pending DOM call on the original document before releasing the owner's operation slot. This is read-only cleanup using the existing browser join. It is not a new hard navigation/process cleanup deadline and does not change the navigation engine's existing lease lifecycle.

The query operation retains the existing native GET-navigation semantics. It does not dispatch click, submit, formdata or invalid events, execute arbitrary page JavaScript, implement POST forms, enter credentials or bypass sign-in.

## Prepared regression coverage

Nine new methods cover the following future assertions:

1. One journaled query, repeated open/resume, original-goal history, separate edit/navigation receipts and journal contents without prompt, field values or URLs.
2. Unsent query refresh after explicit handback, with the same operation and no repeated input; a failed post-rename refresh is reconciled using both known targets.
3. Recovery from a visible verified write that reports failure, with no second query preparation or request.
4. Pause after the durable/native attempt but before the load; no native receipt means no replan or repeated submission.
5. Changed hidden action, unedited submitted value and visible page context, all rejected before dispatch or journal replacement.
6. A pending intent rejecting a different submitter and a new scoped question.
7. A manual password-page handoff requiring explicit return of control, followed by rejection of an identical-looking new authenticated document as replacement field authority.
8. Driver composition for unsent, uncertain, failed verified-write and late-Pause query recovery. It retains the original goal/search, checks pending work before new reading, records query history and does not repeat input or navigation.
9. Driver reconciliation of a pending verified form edit, without treating it as submission or a completed research answer.

These are source-authored loopback fixtures and store fault injections, not executed evidence. No real accounts, sites, models or held-out data were accessed.

## Remaining repair order

1. **Choose new form actions in the default driver.** Introduce an input-bound next-action decision that considers the complete goal, accepted answers, current page, prior readings and form/navigation history. It must choose among supported form preparation, verified query navigation, observed links, recall, scoped questions and intervention. Do not run forms merely as a fallback after failed link selection, drop the goal to a query string or treat an intermediate stage as completion. Wire the existing form planner through the same shared runtime.
2. **Represent form ownership and dependencies for planning.** Bind relevant controls to their actual forms and preserve earlier field receipts when a later stage exposes new controls. A latest-stage continuation does not aggregate all preceding edited fields. Distinguish source text, normalized values, native option identity and user-preserved fields throughout dependent operations.
3. **Recover genuinely changed unsent work.** This checkpoint refreshes equivalent query bindings only. Actual page/form changes or new native documents remain pending. Broader replacement needs a complete-goal replan under durable/native no-attempt proof and an atomic binding update. Attempted actions cannot gain replay authority from a new plan or successful sign-in.
4. **Finish account handoff composition.** Continue visible user-controlled login/provider windows and explicit handback across the host and phone. A redirect may destroy the original form authority. Preserve known effects and remaining requirements, then resolve the pending action honestly; do not reconstruct old native fields or receipts from the new page.
5. **Persist the parent graph and complete cleanup bounds.** Per-form and per-query journals do not reconstruct ordered research history, pending intent or browser state after process loss. Define parent recovery, history restoration, stale-reference disposal and unresponsive WebKit/process cleanup before claiming crash recovery.
6. **Finish browser interaction and research answers.** Rich date/time ranges, location and airport transformations, party/inventory quantities, autocomplete/calendar/custom widgets, dynamic/POST forms, embedded controls, offer association, distinct qualifying counts, prices/fees/availability, ranking and public source links remain open. A prepared or loaded query supplies no independent proof of those facts.
7. **Qualify the actual composition after authorization.** Build/typecheck, run bounded native checks and qualify current model prompts before deferred travel/concert/movie website E2E. Preserve the held-out corpus and 8 GB Mac target. Alternative models and authorized RTX 3080 adaptation remain available after separating application defects from model errors; remote access is still unverified after the earlier SSH timeout.

## Verification performed

Six changed Swift files passed syntax parsing only. Nine embedded JavaScript variants passed `node --check`; temporary syntax files were removed. Xcode project plist syntax and the new source's four project entries were checked. The default and [focused source inventories](browser-research-form-query-inventory.json) match **989** and **306** methods. Local documentation links and whitespace were checked.

No typechecking, builds, tests/assertions, inference, app launch, computer use or real-site E2E ran. No installed application, model or remote desktop was changed. The whole repair goal remains open.
