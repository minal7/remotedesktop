# Retain and reconcile browser research form stages

Parent: `74ae300`. This checkpoint implements a retained form execution stage and native query preparation in source. The default research driver does not yet call these APIs. No current build, test, model run or browser task has qualified this behavior.

## First-principles findings

An accepted plan, an attempted input, a native input receipt, a verified field value, a submitted search and a completed research answer are different facts. Recovery must preserve those distinctions.

1. Recreating a form plan on Resume changes the identities and preconditions used to interpret an earlier attempt. Matching visible text cannot establish that the agent entered it; the user or website might have done so.
2. Cancelling a Swift continuation cannot retract JavaScript already dispatched to WebKit. Releasing the execution lock when the Swift reply is cancelled allows another runner to overlap work that is still changing the page.
3. A journal write can become visible before the store reports an error. Retrying through the same failed store or assuming the write did not happen discards evidence. A fresh store must load the existing record and reconcile the original contract.
4. One research goal can require several forms. Reusing the root task's single journal for every form confuses separate actions; changing the root task to solve that collision loses the original goal and native navigation binding.
5. Explicit user handback refreshes observations. A new observation nonce alone is not a different field or plan. Actual changed content, field membership or values is different and cannot silently inherit the old plan.

## Source changes

`ComputerUseBrowserResearchFormStage` retains the exact input, proposal, text contract and native field adapter before any write or native await. Its identity includes the original task, root goal digest and ordered form-stage index. The stage identity also enters the text contract's digest, while the text task retains the original root task ID. Journals occupy separate `Research Forms/<stage ID>` directories. The existing journal format records identities and statuses, without persisting field values or the user's prompt.

Each execution opens a fresh journal store, loads its record and acquires the existing execution lease before validating the unsent page or running the text engine. The engine borrows that lease; only the enclosing form stage releases it. The original contract must match any recovered journal. Attempted or uncertain steps use the engine's native input-receipt and outcome checks; they cannot be typed again merely because the page looks unchanged. Known writes still go through the journal's compare-and-advance rules when cancellation occurs.

For a wholly unsent stage, the same adapter re-observes and binds the original fields. The comparison ignores only the observation nonce and viewport, which these native field operations do not use as pointer coordinates. Captured page content, document identity, native field correspondence, values and control metadata must still match. This refresh retains the original contract; it does not run a model or discover replacement fields. Changed content is rejected before a durable attempt or input.

The owned browser now exposes a cleanup-only wait for a pending DOM call on the original document. Cancellation, loss of control or an error keeps the form stage and its execution lease occupied until WebKit's callback arrives or the browser is released. Waiters are resumed on the callback or after browser release; the cleanup wait performs no new observation or edit. A page whose callback never arrives must be closed. This is not a new hard cleanup deadline.

The research owner exposes explicit execute/resume methods and records one historical receipt per stage. Pause preserves the stage and invalidates speculative readings. An unresolved form blocks replacement planning, questions and navigation; a repeated identical request resumes the same stage. Retirement cannot publish late history. Successful repetition returns the historical receipt without typing again. That receipt is not evidence that the current page still has the old values.

After a verified stage, the owner can observe the page without rediscovering fields, then prepare a native GET query from the exact submitter and verified text continuation. Native preparation rechecks values and actual input receipts. This API prepares a target only; it neither submits the search nor completes the research goal.

## Prepared regression coverage

Ten new methods in `ComputerUseBrowserFormPlannerTests` cover:

- One retained multi-field execution, repeated execute/resume, private journal contents and native query preparation without navigation.
- Pause after the durable attempt but before input, rejection of replacement work and refusal to invent a missing receipt.
- Pause while a WebKit input handler is still active, retention of the execution lock and receipt-based reconciliation without another edit.
- A visible verified journal write followed by a store error, then recovery through a fresh store without replay.
- A failed attempt write followed by a matching manual value, which cannot supply the missing native receipt.
- An unsent stage surviving explicit handback with a refreshed observation nonce and the original contract.
- Separate ordered stage journals under the same complete goal.
- A replacement browser/owner rejecting an older journal whose native bindings cannot be reconstructed.
- Retirement and browser closure releasing pending cleanup without publishing a completed form receipt.
- Actual page-content changes being rejected before an attempt or edit.

These are authored future assertions. The held HTTP routes and native input handlers were not executed. No current test result is inferred from the source inventory.

## Remaining repair order

1. **Integrate forms with the default driver.** Add an explicit next-step decision among form planning, result reading, observed-link navigation, a scoped question and an intervention. Retain the chosen action before awaiting it; reconcile a pending form before asking the model for another action. Preserve the full original goal and accepted answers.
2. **Retain and journal form-query navigation.** Bind the verified continuation, exact observed submitter, native query target and source policy to the next navigation stage. A form receipt alone must never authorize an arbitrary URL or duplicate submission.
3. **Support dependent forms without losing prior effects.** New field discovery currently clears the DOM input-receipt table. Sequential stage history records earlier work, but the latest continuation does not aggregate all earlier edited fields. Introduce retained field-extension discovery and explicit aggregate continuation rules before treating multi-stage forms as submission-ready.
4. **Recover changed, genuinely unsent plans.** The current stage rejects actual page changes and remains pending. Permit replacement only with durable and native no-attempt evidence under the execution lock, followed by an atomic contract replacement. The existing store's narrower `replaceUnsent` contract is not permission to discard an arbitrary form journal.
5. **Complete account handoff.** Keep login visible and user-controlled, then require explicit handback. A login redirect can replace the original document and destroy field authority. Reconcile known effects, preserve the research goal and present unresolved actions accurately; do not fabricate original field bindings from the new authenticated page. Provider windows and host/phone handoff still need composition work and qualification.
6. **Make the whole research history durable.** Per-form journals do not reconstruct the parent action graph, ordered completed stages, remaining requirements or native browser state after process loss. A replacement owner currently rejects incompatible prior stage bindings. Define durable parent recovery and disposal of unresponsive browser work before claiming crash recovery.
7. **Extend task semantics and result completion.** Date/time ranges, location/airport transforms, richer party and inventory quantities, autocomplete/calendar widgets, POST/dynamic forms, embedded controls, offer association, qualifying result counts, availability, fees, ranking and public source links remain open. Exact field input is intermediate evidence, not proof of a correct travel/concert/movie answer.
8. **Qualify after authorization.** Typecheck/build first, then run bounded native and actual-model checks before real-site E2E. Separate application errors from model errors before changing models or using the authorized RTX 3080 desktop for adaptation. Preserve held-out data and the 8 GB Mac target. Remote SSH access remains unverified after the earlier timeout; this checkpoint did not retry it.

## Verification performed

Five changed Swift files passed syntax parsing only. Six embedded fixture JavaScript snippets passed `node --check`; temporary syntax files were removed. Xcode project syntax and the new source's four project entries were checked. Default and focused source inventories match **980** and **297** methods respectively; see the [focused inventory](browser-form-execution-inventory.json). Documentation links and whitespace were checked.

No typechecking, builds, tests/assertions, model inference, app launch, computer use or live website tasks ran. The installed app, local models and remote desktop were not modified. Syntax and source-registration checks do not qualify the implementation. The complete repair goal remains open.
